import { endpoint, hostPermission, normalizeControlOrigin } from "./sync-core.js";

const form = document.querySelector("#pairing-form");
const status = document.querySelector("#status");
const librarySettings = document.querySelector("#library-settings");
const libraryStatus = document.querySelector("#library-status");
const bookmarkToggle = document.querySelector("#mirror-bookmarks");
const readingListToggle = document.querySelector("#mirror-reading-list");
const fields = {
  origin: document.querySelector("#control-origin"),
  name: document.querySelector("#device-name"),
  code: document.querySelector("#pairing-code")
};

const saved = await chrome.storage.local.get(["controlOrigin", "deviceName", "deviceToken", "mirrorBookmarks", "mirrorReadingList"]);
const [bookmarkGranted, readingListGranted] = await Promise.all([
  chrome.permissions.contains({ permissions: ["bookmarks"] }),
  chrome.permissions.contains({ permissions: ["readingList"] })
]);
fields.origin.value = saved.controlOrigin ?? "";
fields.name.value = saved.deviceName ?? "";
bookmarkToggle.checked = Boolean(saved.mirrorBookmarks && bookmarkGranted);
readingListToggle.checked = Boolean(saved.mirrorReadingList && readingListGranted);
if (saved.mirrorBookmarks && !bookmarkGranted) await chrome.storage.local.set({ mirrorBookmarks: false });
if (saved.mirrorReadingList && !readingListGranted) await chrome.storage.local.set({ mirrorReadingList: false });
librarySettings.hidden = !saved.deviceToken;

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
    librarySettings.hidden = false;
    status.textContent = "Connected. Open the extension to send a tab or window.";
  } catch (error) {
    status.textContent = error.message;
  }
});

bookmarkToggle.addEventListener("change", () => updateLibrarySource("bookmark", bookmarkToggle));
readingListToggle.addEventListener("change", () => updateLibrarySource("reading_list", readingListToggle));
document.querySelector("#sync-now").addEventListener("click", async () => {
  libraryStatus.textContent = "Syncing…";
  try {
    if (bookmarkToggle.checked) await requestLibrarySync("bookmark");
    if (readingListToggle.checked) await requestLibrarySync("reading_list");
    libraryStatus.textContent = "Enabled sources are current.";
  } catch (error) {
    libraryStatus.textContent = error.message;
  }
});

async function updateLibrarySource(kind, toggle) {
  const permission = kind === "bookmark" ? "bookmarks" : "readingList";
  const setting = kind === "bookmark" ? "mirrorBookmarks" : "mirrorReadingList";
  const enabling = toggle.checked;
  libraryStatus.textContent = enabling ? "Requesting access…" : "Removing mirror…";
  try {
    if (enabling) {
      const granted = await chrome.permissions.request({ permissions: [permission] });
      if (!granted) throw new Error(`Chrome did not grant ${kind === "bookmark" ? "bookmark" : "Reading List"} access.`);
      await chrome.storage.local.set({ [setting]: true });
      await requestLibrarySync(kind);
      libraryStatus.textContent = "Mirror enabled and current. Unsupported or credential-bearing URLs stay in Chrome.";
    } else {
      await requestLibraryClear(kind);
      await chrome.storage.local.set({ [setting]: false });
      await chrome.permissions.remove({ permissions: [permission] });
      libraryStatus.textContent = "Mirror removed and permission released.";
    }
  } catch (error) {
    toggle.checked = !enabling;
    await chrome.storage.local.set({ [setting]: !enabling });
    if (enabling) await chrome.permissions.remove({ permissions: [permission] });
    libraryStatus.textContent = error.message;
  }
}

async function requestLibrarySync(kind) {
  const response = await chrome.runtime.sendMessage({ type: "sync-library", kind });
  if (!response?.ok) throw new Error(response?.error ?? "Ghostlight library sync failed.");
}

async function requestLibraryClear(kind) {
  const response = await chrome.runtime.sendMessage({ type: "clear-library", kind });
  if (!response?.ok) throw new Error(response?.error ?? "Ghostlight library removal failed.");
}
