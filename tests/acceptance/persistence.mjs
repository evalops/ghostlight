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
  const publicEndpoint = new URL(endpoint);
  parsed.hostname = publicEndpoint.hostname;
  parsed.port = publicEndpoint.port;
  return parsed.toString();
}

class CDPConnection {
  constructor(socket) {
    this.socket = socket;
    this.nextID = 1;
    this.pending = new Map();
    socket.on("message", (data) => {
      const message = JSON.parse(data.toString());
      if (!message.id || !this.pending.has(message.id)) return;
      const pending = this.pending.get(message.id);
      this.pending.delete(message.id);
      clearTimeout(pending.timer);
      if (message.error) pending.reject(new Error(JSON.stringify(message.error)));
      else pending.resolve(message.result);
    });
  }

  static async open() {
    const response = await fetch(`${endpoint}/json/version`);
    if (!response.ok) throw new Error(`CDP version request failed: ${response.status}`);
    const version = await response.json();
    const socket = new WebSocket(externallyReachableWebSocket(version.webSocketDebuggerUrl));
    await new Promise((resolve, reject) => {
      socket.once("open", resolve);
      socket.once("error", reject);
    });
    return new CDPConnection(socket);
  }

  call(method, params = {}, sessionId) {
    const id = this.nextID++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`CDP ${method} timed out`));
      }, 15000);
      this.pending.set(id, { resolve, reject, timer });
      this.socket.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }));
    });
  }

  close() {
    this.socket.close();
  }
}

async function waitForProofTargets(timeoutMilliseconds = 30000) {
  const deadline = Date.now() + timeoutMilliseconds;
  while (Date.now() < deadline) {
    const allTargets = await listTargets();
    const proofTargets = allTargets.filter((target) => target.type === "page" && proofURLs.includes(target.url));
    if (proofTargets.length === proofURLs.length) return { allTargets, proofTargets };
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
}

if (phase === "after") await new Promise((resolve) => setTimeout(resolve, 5000));
const { allTargets, proofTargets } = await waitForProofTargets();
if (proofTargets.length !== 2) {
  throw new Error(`expected exactly two restored proof targets; found ${proofTargets.length}: ${allTargets.map((target) => target.url).join(", ")}`);
}

await fs.mkdir(outputDir, { recursive: true });
const cdp = await CDPConnection.open();
const evidence = [];
for (const target of proofTargets.sort((left, right) => left.url.localeCompare(right.url))) {
  const attachment = await cdp.call("Target.attachToTarget", { targetId: target.id, flatten: true });
  const runtime = await cdp.call("Runtime.evaluate", {
    expression: "JSON.stringify({title: document.title, url: location.href, cookie: document.cookie, localStorage: localStorage.getItem('ghostlight-acceptance-storage'), body: document.body.innerText})",
    returnByValue: true,
  }, attachment.sessionId);
  const state = JSON.parse(runtime.result.value);
  if (!state.cookie.includes(`ghostlight_acceptance=${expectedMarker}`)) throw new Error(`cookie marker missing from ${state.url}`);
  if (state.localStorage !== expectedMarker) throw new Error(`local-storage marker missing from ${state.url}`);
  const screenshot = await cdp.call("Page.captureScreenshot", { format: "png", fromSurface: true }, attachment.sessionId);
  const suffix = state.url.endsWith("state-a") ? "a" : "b";
  const screenshotPath = `${outputDir}/${phase}-tab-${suffix}.png`;
  await fs.writeFile(screenshotPath, Buffer.from(screenshot.data, "base64"));
  evidence.push({ ...state, screenshot: `${phase}-tab-${suffix}.png` });
}
cdp.close();

const result = { phase, pipeline: "browser-target-cdp-over-loopback", proofTargetCount: proofTargets.length, evidence };
await fs.writeFile(`${outputDir}/${phase}-evidence.json`, `${JSON.stringify(result, null, 2)}\n`);
console.log(JSON.stringify(result, null, 2));
