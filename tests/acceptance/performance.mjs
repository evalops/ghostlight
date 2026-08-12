import { createHash } from "node:crypto";
import fs from "node:fs/promises";
import { basename, dirname } from "node:path";
import { performance } from "node:perf_hooks";
import { chromium } from "playwright";

const [viewerURL, displayName, password, outputPath] = process.argv.slice(2);
if (!viewerURL || !displayName || !password || !outputPath) {
  throw new Error("usage: performance.mjs <viewer-url> <display-name> <password> <output-json>");
}
const requestedCodec = process.env.GHOSTLIGHT_PERFORMANCE_CODEC ?? "default";
if (!new Set(["default", "h264"]).has(requestedCodec)) {
  throw new Error("GHOSTLIGHT_PERFORMANCE_CODEC must be default or h264");
}

const browser = await chromium.launch({
  headless: true,
  executablePath: process.env.GHOSTLIGHT_PERFORMANCE_BROWSER || undefined,
});
const context = await browser.newContext();
await context.addInitScript(({ requestedCodec: codec }) => {
  const peers = [];
  const nativePeerConnection = window.RTCPeerConnection;
  window.__ghostlightPeerConnections = peers;
  window.__ghostlightH264Supported = Boolean(
    window.RTCRtpReceiver?.getCapabilities?.("video")?.codecs?.some(
      (entry) => entry.mimeType.toLowerCase() === "video/h264"
    )
  );
  if (!nativePeerConnection) return;

  const applyCodecPreferences = (peer) => {
    if (codec !== "h264" || !window.__ghostlightH264Supported) return;
    const capabilities = window.RTCRtpReceiver.getCapabilities("video");
    const h264 = capabilities.codecs.filter((entry) => entry.mimeType.toLowerCase() === "video/h264");
    const other = capabilities.codecs.filter((entry) => entry.mimeType.toLowerCase() !== "video/h264");
    for (const transceiver of peer.getTransceivers()) {
      if (transceiver.receiver?.track?.kind === "video") {
        transceiver.setCodecPreferences([...h264, ...other]);
      }
    }
  };

  const trackedPeerConnection = function (...args) {
    const peer = new nativePeerConnection(...args);
    peers.push(peer);
    if (codec === "h264") {
      for (const method of ["createOffer", "createAnswer"]) {
        const createDescription = peer[method].bind(peer);
        peer[method] = async (...methodArgs) => {
          applyCodecPreferences(peer);
          return createDescription(...methodArgs);
        };
      }
    }
    return peer;
  };
  trackedPeerConnection.prototype = nativePeerConnection.prototype;
  Object.setPrototypeOf(trackedPeerConnection, nativePeerConnection);
  try {
    Object.defineProperty(window, "RTCPeerConnection", {
      configurable: true,
      value: trackedPeerConnection,
      writable: true,
    });
  } catch {
    window.RTCPeerConnection = trackedPeerConnection;
  }
}, { requestedCodec });

const page = await context.newPage();
await page.goto(viewerURL, { waitUntil: "domcontentloaded" });
await page.getByPlaceholder(/display name/i).fill(displayName);
await page.getByPlaceholder(/password/i).fill(password);
await page.getByRole("button", { name: /connect/i }).click();
await page.locator("video").waitFor({ state: "attached", timeout: 30000 });
await page.waitForFunction(() => {
  const video = document.querySelector("video");
  return video && video.readyState >= HTMLMediaElement.HAVE_CURRENT_DATA;
}, null, { timeout: 30000 });

const collectStats = () => page.evaluate(async () => {
  const reports = [];
  for (const peer of window.__ghostlightPeerConnections ?? []) {
    try {
      const report = await peer.getStats();
      report.forEach((entry) => reports.push({ ...entry }));
    } catch {
      // A peer can close while the measurement is collecting a report.
    }
  }
  const inbound = reports.filter((report) => report.type === "inbound-rtp" && report.kind === "video");
  const codecs = reports.filter((report) => report.type === "codec");
  const totals = inbound.reduce((result, report) => ({
    bytesReceived: result.bytesReceived + (report.bytesReceived ?? 0),
    framesDecoded: result.framesDecoded + (report.framesDecoded ?? 0),
    framesDropped: result.framesDropped + (report.framesDropped ?? 0),
  }), { bytesReceived: 0, framesDecoded: 0, framesDropped: 0 });
  const video = document.querySelector("video");
  return {
    inboundCount: inbound.length,
    totals,
    codecIds: inbound.map((report) => report.codecId).filter(Boolean),
    codecs,
    video: video?.getVideoPlaybackQuality?.() ?? null,
    h264Supported: window.__ghostlightH264Supported,
  };
});

const start = performance.now();
const startStats = await collectStats();
const inputStart = performance.now();
await page.keyboard.press("Shift");
const frameCallbackDelayMs = await page.evaluate(() => new Promise((resolve) => {
  const begun = performance.now();
  const video = document.querySelector("video");
  if (video && "requestVideoFrameCallback" in video) {
    video.requestVideoFrameCallback(() => resolve(performance.now() - begun));
  } else {
    requestAnimationFrame(() => resolve(performance.now() - begun));
  }
}));
const inputToPresentedFrameMs = performance.now() - inputStart;

await page.waitForTimeout(10000);
const end = performance.now();
const endStats = await collectStats();
const elapsedSeconds = (end - start) / 1000;
const codec = endStats.codecs.find((entry) => endStats.codecIds.includes(entry.id));
const decodedFrames = endStats.totals.framesDecoded - startStats.totals.framesDecoded;
const droppedFrames = endStats.totals.framesDropped - startStats.totals.framesDropped;
const receivedBytes = endStats.totals.bytesReceived - startStats.totals.bytesReceived;
const activeMedia = startStats.inboundCount > 0 && endStats.inboundCount > 0 && decodedFrames > 0;
const result = {
  status: activeMedia ? "measured" : "blocked",
  capturedAt: new Date().toISOString(),
  viewerEndpointSha256: createHash("sha256").update(viewerURL).digest("hex"),
  requestedCodec,
  h264Supported: endStats.h264Supported,
  sampleSeconds: elapsedSeconds,
  inputToPresentedFrameMs,
  frameCallbackDelayMs,
  decodedFrames,
  droppedFrames,
  receivedBytes,
  bitrateBitsPerSecond: receivedBytes * 8 / elapsedSeconds,
  codec: codec ? {
    id: codec.id,
    mimeType: codec.mimeType,
    clockRate: codec.clockRate,
    sdpFmtpLine: codec.sdpFmtpLine ?? null,
  } : null,
  limitations: [
    "Input latency is measured from browser keyboard dispatch until the next presented WebRTC video frame.",
    "The metric does not include physical keyboard polling or display scanout.",
    "The H.264 run only changes codec preference when the browser advertises H.264 receiver capability; the Neko default remains unchanged.",
  ],
  decision: requestedCodec === "default"
    ? "Retain the pinned Neko default codec until a paired H.264 run and native WKWebView receipt show a supported improvement."
    : endStats.h264Supported
      ? "This H.264 candidate is measurement-only; retain the pinned Neko default until the paired receipts are reviewed."
      : "H.264 receiver capability was absent; the H.264 comparison was skipped.",
};
await fs.mkdir(dirname(outputPath), { recursive: true });
const encoded = `${JSON.stringify(result, null, 2)}\n`;
await fs.writeFile(outputPath, encoded);
const digest = createHash("sha256").update(encoded).digest("hex");
await fs.writeFile(`${outputPath}.sha256`, `${digest}  ${basename(outputPath)}\n`);
console.log(JSON.stringify(result, null, 2));
await browser.close();
if (!activeMedia) {
  throw new Error("no decoded inbound video frames were observed; refusing to publish a measured receipt");
}
