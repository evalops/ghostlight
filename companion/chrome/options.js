import { endpoint, hostPermission, normalizeControlOrigin } from "./sync-core.js";

const form = document.querySelector("#pairing-form");
const status = document.querySelector("#status");
const fields = {
  origin: document.querySelector("#control-origin"),
  name: document.querySelector("#device-name"),
  code: document.querySelector("#pairing-code")
};

const saved = await chrome.storage.local.get(["controlOrigin", "deviceName"]);
fields.origin.value = saved.controlOrigin ?? "";
fields.name.value = saved.deviceName ?? "";

form.addEventListener("submit", async (event) => {
  event.preventDefault();
  status.textContent = "Connecting…";
  try {
    const controlOrigin = normalizeControlOrigin(fields.origin.value);
    const deviceName = fields.name.value.trim();
    const pairingCode = fields.code.value.trim();
    const granted = await chrome.permissions.request({ origins: [hostPermission(controlOrigin)] });
    if (!granted) throw new Error("Chrome did not grant access to the Ghostlight control URL.");
    const { deviceID: existingID } = await chrome.storage.local.get("deviceID");
    const deviceID = existingID ?? crypto.randomUUID();
    const response = await fetch(endpoint(controlOrigin, "v1/chrome-pairings/redeem"), {
      method: "POST",
      headers: { "Accept": "application/json", "Content-Type": "application/json" },
      body: JSON.stringify({ pairing_code: pairingCode, device_id: deviceID, device_name: deviceName })
    });
    const payload = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error(payload?.error?.message ?? `Ghostlight returned HTTP ${response.status}.`);
    await chrome.storage.local.set({ controlOrigin, deviceName, deviceID, deviceToken: payload.device_token });
    fields.code.value = "";
    status.textContent = "Connected. Click the extension on any normal web page to send that tab.";
  } catch (error) {
    status.textContent = error.message;
  }
});
