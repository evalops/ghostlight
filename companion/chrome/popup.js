import { endpoint, safeHandoff, safeHandoffs } from "./sync-core.js";

const status = document.querySelector("#status");
const buttons = [...document.querySelectorAll("button")];

document.querySelector("#send-tab").addEventListener("click", () => run(async () => {
  const [tab] = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
  await send("v1/chrome-handoffs", safeHandoff(tab), crypto.randomUUID());
  status.textContent = "Sent this tab.";
}));

document.querySelector("#send-window").addEventListener("click", () => run(async () => {
  const granted = await chrome.permissions.request({ permissions: ["tabs"] });
  if (!granted) throw new Error("Window handoff needs permission to read tab titles and URLs.");
  const tabs = (await chrome.tabs.query({ currentWindow: true })).sort((left, right) => left.index - right.index);
  const handoffs = safeHandoffs(tabs);
  await send("v1/chrome-handoff-batches", { group_id: crypto.randomUUID(), tabs: handoffs }, crypto.randomUUID());
  status.textContent = `Sent ${handoffs.length} tabs in window order.`;
}));

async function send(path, body, idempotencyKey) {
  const { controlOrigin, deviceToken } = await chrome.storage.local.get(["controlOrigin", "deviceToken"]);
  if (!controlOrigin || !deviceToken) {
    await chrome.runtime.openOptionsPage();
    throw new Error("Connect Chrome to Ghostlight first.");
  }
  const response = await fetch(endpoint(controlOrigin, path), {
    method: "POST",
    headers: {
      "Accept": "application/json",
      "Content-Type": "application/json",
      "Authorization": `Bearer ${deviceToken}`,
      "Idempotency-Key": idempotencyKey
    },
    body: JSON.stringify(body)
  });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(payload?.error?.message ?? `Ghostlight returned HTTP ${response.status}.`);
}

async function run(operation) {
  buttons.forEach((button) => { button.disabled = true; });
  status.textContent = "Sending…";
  try {
    await operation();
  } catch (error) {
    status.textContent = error.message;
  } finally {
    buttons.forEach((button) => { button.disabled = false; });
  }
}
