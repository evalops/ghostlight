import { endpoint, safeHandoff } from "./sync-core.js";

chrome.runtime.onInstalled.addListener(async () => {
  await chrome.storage.local.setAccessLevel({ accessLevel: "TRUSTED_CONTEXTS" });
});

chrome.action.onClicked.addListener(async (tab) => {
  try {
    const handoff = safeHandoff(tab);
    const { controlOrigin, deviceToken } = await chrome.storage.local.get(["controlOrigin", "deviceToken"]);
    if (!controlOrigin || !deviceToken) {
      await chrome.runtime.openOptionsPage();
      return;
    }
    const response = await fetch(endpoint(controlOrigin, "v1/chrome-handoffs"), {
      method: "POST",
      headers: {
        "Accept": "application/json",
        "Content-Type": "application/json",
        "Authorization": `Bearer ${deviceToken}`,
        "Idempotency-Key": crypto.randomUUID()
      },
      body: JSON.stringify(handoff)
    });
    if (!response.ok) {
      const payload = await response.json().catch(() => ({}));
      throw new Error(payload?.error?.message ?? `Ghostlight returned HTTP ${response.status}.`);
    }
    await showBadge("✓", "#247A3C");
  } catch (error) {
    await showBadge("!", "#B42318");
    console.error("Ghostlight handoff failed", error);
  }
});

async function showBadge(text, color) {
  await chrome.action.setBadgeBackgroundColor({ color });
  await chrome.action.setBadgeText({ text });
  setTimeout(() => chrome.action.setBadgeText({ text: "" }), 2000);
}
