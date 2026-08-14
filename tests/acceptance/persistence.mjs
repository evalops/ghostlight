import fs from "node:fs/promises";

const [cdpEndpoint, viewerEndpoint, phase, outputDir] = process.argv.slice(2);
if (!cdpEndpoint || !viewerEndpoint || !["before", "after"].includes(phase) || !outputDir) {
  throw new Error("usage: persistence.mjs <cdp-endpoint> <viewer-endpoint> <before|after> <output-dir>");
}

const proofURLs = ["http://127.0.0.1:18083/state-a", "http://127.0.0.1:18083/state-b"];
const browserAgentID = "okabifedphcnokaehflbkmpfphleoaha";
const browserAgentURL = `chrome-extension://${browserAgentID}/service-worker.js`;

async function listTargets() {
  const response = await fetch(`${cdpEndpoint}/json/list`);
  if (!response.ok) throw new Error(`CDP target listing failed: ${response.status}`);
  return response.json();
}

async function waitForBrowserAgent(timeoutMilliseconds = 30000) {
  const deadline = Date.now() + timeoutMilliseconds;
  let observed = [];
  while (Date.now() < deadline) {
    observed = (await listTargets()).filter((target) => target.type === "service_worker");
    const agent = observed.find((target) => target.url === browserAgentURL);
    if (agent) return agent.url;
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  throw new Error(`packaged browser agent service worker did not load; expected ${browserAgentURL}; observed ${observed.map((target) => target.url).join(", ") || "none"}`);
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
    const response = await fetch(`${cdpEndpoint}/json/close/${target.id}`, { method: "PUT" });
    if (!response.ok) throw new Error(`CDP target close failed: ${response.status} ${await response.text()}`);
  }
  for (const url of proofURLs) {
    const response = await fetch(`${cdpEndpoint}/json/new?${encodeURIComponent(url)}`, { method: "PUT" });
    if (!response.ok) throw new Error(`CDP target creation failed: ${response.status} ${await response.text()}`);
  }
}

const loadedBrowserAgentURL = await waitForBrowserAgent();
if (phase === "after") await new Promise((resolve) => setTimeout(resolve, 5000));
const { allTargets, proofTargets } = await waitForProofTargets();
if (proofTargets.length !== proofURLs.length) {
  throw new Error(`expected exactly two restored proof targets; found ${proofTargets.length}: ${allTargets.map((target) => target.url).join(", ")}`);
}

await fs.mkdir(outputDir, { recursive: true });
const evidence = [];
for (const target of proofTargets.sort((left, right) => left.url.localeCompare(right.url))) {
  const activated = await fetch(`${cdpEndpoint}/json/activate/${target.id}`, { method: "PUT" });
  if (!activated.ok) throw new Error(`CDP target activation failed: ${activated.status} ${await activated.text()}`);
  await new Promise((resolve) => setTimeout(resolve, 750));

  const screenshot = await fetch(`${viewerEndpoint}/screenshot.jpg?pwd=acceptance-admin-password`);
  if (!screenshot.ok) throw new Error(`Neko screenshot failed: ${screenshot.status}`);
  const suffix = target.url.endsWith("state-a") ? "a" : "b";
  const screenshotName = `${phase}-tab-${suffix}.jpg`;
  await fs.writeFile(`${outputDir}/${screenshotName}`, Buffer.from(await screenshot.arrayBuffer()));
  evidence.push({ id: target.id, title: target.title, type: target.type, url: target.url, screenshot: screenshotName });
}

const result = {
  phase,
  pipeline: "browser-target-restoration-server-state-and-neko-screenshot",
  browserAgent: { id: browserAgentID, serviceWorkerURL: loadedBrowserAgentURL },
  proofTargetCount: proofTargets.length,
  evidence,
};
await fs.writeFile(`${outputDir}/${phase}-evidence.json`, `${JSON.stringify(result, null, 2)}\n`);
console.log(JSON.stringify(result, null, 2));
