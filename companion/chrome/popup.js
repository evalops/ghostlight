import { clearPendingDelivery, endpoint, pendingDelivery, safeHandoff, safeHandoffs } from "./sync-core.js";

const status = document.querySelector("#status");
const buttons = [...document.querySelectorAll("button")];

document.querySelector("#send-tab").addEventListener("click", () => run(async () => {
  const [tab] = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
  await send("v1/chrome-handoffs", safeHandoff(tab));
  status.textContent = "Sent this tab.";
}));

document.querySelector("#send-window").addEventListener("click", () => run(async () => {
  const granted = await chrome.permissions.request({ permissions: ["tabs"] });
  if (!granted) throw new Error("Window handoff needs permission to read tab titles and URLs.");
  const tabs = (await chrome.tabs.query({ currentWindow: true })).sort((left, right) => left.index - right.index);
  const handoffs = safeHandoffs(tabs);
  await send("v1/chrome-handoff-batches", { tabs: handoffs });
  status.textContent = `Sent ${handoffs.length} tabs in window order.`;
}));

async function send(path, body) {
  const { controlOrigin, deviceToken } = await chrome.storage.local.get(["controlOrigin", "deviceToken"]);
  if (!controlOrigin || !deviceToken) {
    await chrome.runtime.openOptionsPage();
    throw new Error("Connect Chrome to Ghostlight first.");
  }
  const delivery = await pendingDelivery(chrome.storage.local, path, body);
  const requestBody = path === "v1/chrome-handoff-batches" ? { group_id: delivery.key, ...body } : body;
  const response = await fetch(endpoint(controlOrigin, path), {
    method: "POST",
    headers: {
      "Accept": "application/json",
      "Content-Type": "application/json",
      "Authorization": `Bearer ${deviceToken}`,
      "Idempotency-Key": delivery.key
    },
    body: JSON.stringify(requestBody)
  });
  const payload = await response.json().catch(() => ({}));
  await clearPendingDelivery(chrome.storage.local, delivery);
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
