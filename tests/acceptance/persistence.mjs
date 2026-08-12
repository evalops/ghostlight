import fs from "node:fs/promises";
import { chromium } from "playwright";

const [cdpEndpoint, viewerEndpoint, phase, outputDir, expectedMarker] = process.argv.slice(2);
if (!cdpEndpoint || !viewerEndpoint || !["before", "after"].includes(phase) || !outputDir || !expectedMarker) {
  throw new Error("usage: persistence.mjs <cdp-endpoint> <viewer-endpoint> <before|after> <output-dir> <marker>");
}

const proofURLs = ["http://127.0.0.1:18083/state-a", "http://127.0.0.1:18083/state-b"];

function isProofPage(page) {
  return proofURLs.includes(page.url());
}

async function waitForProofPages(context, timeoutMilliseconds = 30000) {
  const deadline = Date.now() + timeoutMilliseconds;
  while (Date.now() < deadline) {
    const pages = context.pages().filter(isProofPage).sort((left, right) => left.url().localeCompare(right.url()));
    if (pages.length === proofURLs.length) return pages;
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  const current = context.pages().map((page) => page.url()).join(", ");
  throw new Error(`proof tabs did not restore: ${current}`);
}

const browser = await chromium.connectOverCDP(cdpEndpoint);
try {
  const [context] = browser.contexts();
  if (!context) throw new Error("Chromium exposed no browser context");

  let proofPages;
  if (phase === "before") {
    const availablePages = context.pages();
    proofPages = [];
    for (let index = 0; index < proofURLs.length; index += 1) {
      const page = availablePages[index] || await context.newPage();
      await page.goto(proofURLs[index], { waitUntil: "domcontentloaded" });
      await page.waitForSelector("#storage");
      proofPages.push(page);
    }
  } else {
    proofPages = await waitForProofPages(context);
  }

  await fs.mkdir(outputDir, { recursive: true });
  const evidence = [];
  for (let index = 0; index < proofPages.length; index += 1) {
    const page = proofPages[index];
    await page.screenshot({ path: `${outputDir}/${phase}-tab-${index + 1}.png` });
    evidence.push({ tab: index + 1, url: page.url(), screenshot: `${phase}-tab-${index + 1}.png` });
  }
  await fs.writeFile(
    `${outputDir}/${phase}-evidence.json`,
    `${JSON.stringify({ phase, automation: "Playwright", expected_marker: expectedMarker, viewer_endpoint: new URL(viewerEndpoint).origin, evidence }, null, 2)}\n`,
  );
  console.log(JSON.stringify({ phase, tabs: evidence.length, restored: phase === "after" }));
} finally {
  browser.disconnect();
}
