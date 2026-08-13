import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import fs from "node:fs/promises";
import { basename, dirname } from "node:path";
import { performance } from "node:perf_hooks";
import { chromium } from "playwright";

// Pass/fail gate thresholds ported from the buildGates semantics in
// tools/measure-streaming-performance.mjs, scaled to what this 10-second
// getStats window observes (no causal visual events, no paired control receipt).
const TARGET_FPS = Number(process.env.GHOSTLIGHT_PERFORMANCE_TARGET_FPS ?? 25); // full-harness default target rate
const MIN_ACTUAL_TO_TARGET_FPS_RATIO = 0.9; // same floor as the full harness: allow ~10% encoder/jitter slack
const MAX_DROPPED_FRAME_RATIO = 0.01; // the full harness gates drops against a paired control; a standalone run needs an absolute ceiling
const MIN_BITRATE_BITS_PER_SECOND = 1; // decoded frames with zero received bytes means the stats are untrustworthy

function evaluateGates({ activeMedia, decodedFrames, droppedFrames, bitrateBitsPerSecond, elapsedSeconds, requiredEvidence = {} }) {
  const actualToTargetFpsRatio = elapsedSeconds > 0 && TARGET_FPS > 0
    ? decodedFrames / elapsedSeconds / TARGET_FPS
    : null;
  const droppedFrameRatio = decodedFrames + droppedFrames > 0
    ? droppedFrames / (decodedFrames + droppedFrames)
    : null;
  const failures = [];
  if (!activeMedia) {
    failures.push("no decoded inbound video frames were observed; refusing to publish a measured receipt");
  }
  if (actualToTargetFpsRatio === null || actualToTargetFpsRatio < MIN_ACTUAL_TO_TARGET_FPS_RATIO) {
    failures.push(`actual-to-target fps ratio ${actualToTargetFpsRatio?.toFixed(3) ?? "unavailable"} is below the ${MIN_ACTUAL_TO_TARGET_FPS_RATIO} floor (target ${TARGET_FPS} fps)`);
  }
  if (droppedFrameRatio === null || droppedFrameRatio > MAX_DROPPED_FRAME_RATIO) {
    failures.push(`dropped-frame ratio ${droppedFrameRatio?.toFixed(4) ?? "unavailable"} exceeds the ${MAX_DROPPED_FRAME_RATIO} ceiling`);
  }
  if (!(bitrateBitsPerSecond >= MIN_BITRATE_BITS_PER_SECOND)) {
    failures.push(`bitrate ${bitrateBitsPerSecond.toFixed(0)} bits/s is below the ${MIN_BITRATE_BITS_PER_SECOND} bits/s floor`);
  }
  const evidence = {
    exact_source: requiredEvidence.exact_source === true,
    direct_selected_udp: requiredEvidence.direct_selected_udp === true,
    causal_x11_client_pixel: requiredEvidence.causal_x11_client_pixel === true,
    webrtc_dropped_frames: requiredEvidence.webrtc_dropped_frames === true,
    process_cpu_memory: requiredEvidence.process_cpu_memory === true,
  };
  for (const [name, passed] of Object.entries(evidence)) {
    if (!passed) failures.push(`required ${name.replaceAll("_", " ")} evidence is missing`);
  }
  return {
    gates: {
      active_media: activeMedia,
      actual_to_target_fps_ratio: actualToTargetFpsRatio,
      dropped_frame_ratio: droppedFrameRatio,
      bitrate_bits_per_second: bitrateBitsPerSecond,
      ...evidence,
      passed: failures.length === 0,
    },
    failures,
  };
}

function runGateSelfTests() {
  const evidence = {
    exact_source: true,
    direct_selected_udp: true,
    causal_x11_client_pixel: true,
    webrtc_dropped_frames: true,
    process_cpu_memory: true,
    cdp_available: false,
  };
  const passing = evaluateGates({ activeMedia: true, decodedFrames: 250, droppedFrames: 1, bitrateBitsPerSecond: 3_000_000, elapsedSeconds: 10, requiredEvidence: evidence });
  assert.equal(passing.gates.passed, true);
  assert.deepEqual(passing.failures, []);
  assert.equal(evaluateGates({ activeMedia: false, decodedFrames: 0, droppedFrames: 0, bitrateBitsPerSecond: 0, elapsedSeconds: 10, requiredEvidence: evidence }).gates.passed, false);
  assert.equal(evaluateGates({ activeMedia: true, decodedFrames: 100, droppedFrames: 0, bitrateBitsPerSecond: 3_000_000, elapsedSeconds: 10, requiredEvidence: evidence }).gates.passed, false);
  assert.equal(evaluateGates({ activeMedia: true, decodedFrames: 250, droppedFrames: 30, bitrateBitsPerSecond: 3_000_000, elapsedSeconds: 10, requiredEvidence: evidence }).gates.passed, false);
  assert.equal(evaluateGates({ activeMedia: true, decodedFrames: 250, droppedFrames: 1, bitrateBitsPerSecond: 0, elapsedSeconds: 10, requiredEvidence: evidence }).gates.passed, false);
  assert.equal(evaluateGates({ activeMedia: true, decodedFrames: 250, droppedFrames: 1, bitrateBitsPerSecond: 3_000_000, elapsedSeconds: 10, requiredEvidence: { ...evidence, direct_selected_udp: false } }).gates.passed, false);
  console.log(JSON.stringify({ acceptance_performance_gates_self_test: "passed" }));
}

if (process.argv.includes("--self-test")) {
  runGateSelfTests();
  process.exit(0);
}

const [viewerURL, displayName, outputPath] = process.argv.slice(2);
const password = process.env.GHOSTLIGHT_PERFORMANCE_NEKO_PASSWORD ?? "";
if (!viewerURL || !displayName || !password || !outputPath) {
  throw new Error("usage: GHOSTLIGHT_PERFORMANCE_NEKO_PASSWORD=<password> performance.mjs <viewer-url> <display-name> <output-json>");
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
const phaseStart = performance.now();
await page.keyboard.press("Shift");
const nextPresentedFrameCallbackDelayMs = await page.evaluate(() => new Promise((resolve) => {
  const begun = performance.now();
  const video = document.querySelector("video");
  if (video && "requestVideoFrameCallback" in video) {
    video.requestVideoFrameCallback(() => resolve(performance.now() - begun));
  } else {
    requestAnimationFrame(() => resolve(performance.now() - begun));
  }
}));
const dispatchToNextPresentedFramePhaseMs = performance.now() - phaseStart;

await page.waitForTimeout(10000);
const end = performance.now();
const endStats = await collectStats();
const elapsedSeconds = (end - start) / 1000;
const codec = endStats.codecs.find((entry) => endStats.codecIds.includes(entry.id));
const decodedFrames = endStats.totals.framesDecoded - startStats.totals.framesDecoded;
const droppedFrames = endStats.totals.framesDropped - startStats.totals.framesDropped;
const receivedBytes = endStats.totals.bytesReceived - startStats.totals.bytesReceived;
const activeMedia = startStats.inboundCount > 0 && endStats.inboundCount > 0 && decodedFrames > 0;
const bitrateBitsPerSecond = receivedBytes * 8 / elapsedSeconds;
const { gates, failures: gateFailures } = evaluateGates({
  activeMedia,
  decodedFrames,
  droppedFrames,
  bitrateBitsPerSecond,
  elapsedSeconds,
  requiredEvidence: {
    exact_source: false,
    direct_selected_udp: false,
    causal_x11_client_pixel: false,
    webrtc_dropped_frames: Number.isFinite(droppedFrames),
    process_cpu_memory: false,
  },
});
const result = {
  status: gates.passed ? "measured" : "blocked",
  capturedAt: new Date().toISOString(),
  viewerEndpointSha256: createHash("sha256").update(viewerURL).digest("hex"),
  requestedCodec,
  h264Supported: endStats.h264Supported,
  sampleSeconds: elapsedSeconds,
  dispatchToNextPresentedFramePhaseMs,
  nextPresentedFrameCallbackDelayMs,
  decodedFrames,
  droppedFrames,
  receivedBytes,
  bitrateBitsPerSecond,
  codec: codec ? {
    id: codec.id,
    mimeType: codec.mimeType,
    clockRate: codec.clockRate,
    sdpFmtpLine: codec.sdpFmtpLine ?? null,
  } : null,
  limitations: [
    "The dispatch-to-next-frame phase starts immediately before synthetic browser keyboard dispatch and ends at the next presented WebRTC video frame.",
    "The observed frame is not proven to have been caused by the keyboard event, so this phase metric is not input latency or an input-to-photon measurement.",
    "The H.264 run only changes codec preference when the browser advertises H.264 receiver capability; it does not change the server pipeline.",
    "The pass/fail gates are standalone thresholds without a paired control receipt; tools/measure-streaming-performance.mjs remains the non-regression authority.",
    "This standalone browser smoke does not collect exact-source, direct selected-UDP, causal X11/client-pixel, or process CPU-memory evidence, so it fails closed and cannot publish a measured benchmark receipt.",
    "CDP diagnostics are optional and absent from the required evidence gates.",
  ],
  decision: requestedCodec === "default"
    ? "The runtime default is H.264; pair this receipt with a native WKWebView run to confirm power-efficient VideoToolbox decode on the Mac."
    : endStats.h264Supported
      ? "Compare this H.264 candidate receipt against the default-codec control and the native WKWebView receipt before changing the runtime default again."
      : "H.264 receiver capability was absent; the H.264 comparison was skipped.",
  gates,
};
await fs.mkdir(dirname(outputPath), { recursive: true });
const encoded = `${JSON.stringify(result, null, 2)}\n`;
await fs.writeFile(outputPath, encoded);
const digest = createHash("sha256").update(encoded).digest("hex");
await fs.writeFile(`${outputPath}.sha256`, `${digest}  ${basename(outputPath)}\n`);
console.log(JSON.stringify(result, null, 2));
await browser.close();
if (gateFailures.length > 0) {
  console.error(`performance gates failed:\n${gateFailures.map((failure) => `- ${failure}`).join("\n")}`);
  process.exitCode = 1;
}
