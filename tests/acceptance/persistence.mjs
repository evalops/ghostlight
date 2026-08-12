import fs from "node:fs/promises";
import WebSocket from "ws";

const [endpoint, phase, outputDir, expectedMarker] = process.argv.slice(2);
if (!endpoint || !["before", "after"].includes(phase) || !outputDir || !expectedMarker) {
  throw new Error("usage: persistence.mjs <cdp-endpoint> <before|after> <output-dir> <marker>");
}

const proofURLs = ["http://127.0.0.1:18083/state-a", "http://127.0.0.1:18083/state-b"];

async function listTargets() {
  const response = await fetch(`${endpoint}/json/list`);
  if (!response.ok) throw new Error(`CDP target listing failed: ${response.status}`);
  return response.json();
}

function externallyReachableWebSocket(url) {
  const parsed = new URL(url);
  parsed.hostname = new URL(endpoint).hostname;
  parsed.port = new URL(endpoint).port;
  return parsed.toString();
}

async function callTarget(webSocketDebuggerUrl, method, params = {}) {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(webSocketDebuggerUrl);
    const id = 1;
    let opened = false;
    const timer = setTimeout(() => {
      socket.close();
      reject(new Error(`CDP ${method} timed out (socket_opened=${opened})`));
    }, 15000);
    socket.once("open", () => {
      opened = true;
      socket.send(JSON.stringify({ id, method, params }));
    });
    socket.on("message", (data) => {
      const message = JSON.parse(data.toString());
      if (message.id !== id) return;
      clearTimeout(timer);
      socket.close();
      if (message.error) reject(new Error(JSON.stringify(message.error)));
      else resolve(message.result);
    });
    socket.once("error", (error) => {
      clearTimeout(timer);
      reject(new Error(`CDP ${method} WebSocket error: ${error.message}`));
    });
  });
}

async function waitForProofTargets(timeoutMilliseconds = 30000) {
  const deadline = Date.now() + timeoutMilliseconds;
  let targets = [];
  while (Date.now() < deadline) {
    const allTargets = await listTargets();
    targets = allTargets.filter((target) => target.type === "page" && proofURLs.includes(target.url));
    if (targets.length === proofURLs.length) return { allTargets, proofTargets: targets };
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  const allTargets = await listTargets();
  throw new Error(`proof targets did not finish navigating: ${allTargets.map((target) => `${target.url} (${target.title})`).join(", ")}`);
}

if (phase === "before") {
  const existing = (await listTargets()).filter((target) => proofURLs.includes(target.url));
  for (const target of existing) {
    await fetch(`${endpoint}/json/close/${target.id}`, { method: "PUT" });
  }
  for (const url of proofURLs) {
    const response = await fetch(`${endpoint}/json/new?${encodeURIComponent(url)}`, { method: "PUT" });
    if (!response.ok) throw new Error(`CDP target creation failed: ${response.status} ${await response.text()}`);
  }
  await new Promise((resolve) => setTimeout(resolve, 1500));
}

await new Promise((resolve) => setTimeout(resolve, phase === "after" ? 5000 : 1500));
const { allTargets, proofTargets } = await waitForProofTargets();
if (proofTargets.length !== 2) {
  throw new Error(`expected exactly two restored proof targets; found ${proofTargets.length}: ${allTargets.map((target) => target.url).join(", ")}`);
}

await fs.mkdir(outputDir, { recursive: true });
const evidence = [];
for (const target of proofTargets.sort((left, right) => left.url.localeCompare(right.url))) {
  const webSocketDebuggerUrl = externallyReachableWebSocket(target.webSocketDebuggerUrl);
  const runtime = await callTarget(webSocketDebuggerUrl, "Runtime.evaluate", {
    expression: "JSON.stringify({title: document.title, url: location.href, cookie: document.cookie, localStorage: localStorage.getItem('ghostlight-acceptance-storage'), body: document.body.innerText})",
    returnByValue: true,
  });
  const state = JSON.parse(runtime.result.value);
  if (!state.cookie.includes(`ghostlight_acceptance=${expectedMarker}`)) throw new Error(`cookie marker missing from ${state.url}`);
  if (state.localStorage !== expectedMarker) throw new Error(`local-storage marker missing from ${state.url}`);
  const screenshot = await callTarget(webSocketDebuggerUrl, "Page.captureScreenshot", { format: "png", fromSurface: true });
  const suffix = state.url.endsWith("state-a") ? "a" : "b";
  const screenshotPath = `${outputDir}/${phase}-tab-${suffix}.png`;
  await fs.writeFile(screenshotPath, Buffer.from(screenshot.data, "base64"));
  evidence.push({ ...state, screenshot: `${phase}-tab-${suffix}.png` });
}

const result = { phase, pipeline: "version-neutral-cdp-over-loopback", proofTargetCount: proofTargets.length, evidence };
await fs.writeFile(`${outputDir}/${phase}-evidence.json`, `${JSON.stringify(result, null, 2)}\n`);
console.log(JSON.stringify(result, null, 2));
