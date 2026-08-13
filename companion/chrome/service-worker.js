import { bookmarkItems, endpoint, readingListItems } from "./sync-core.js";

void chrome.storage.local.setAccessLevel({ accessLevel: "TRUSTED_CONTEXTS" });

chrome.runtime.onInstalled.addListener(async () => {
  await ensureRepairAlarm();
  await syncEnabledLibraries();
});

chrome.runtime.onStartup.addListener(async () => {
  await ensureRepairAlarm();
  await syncEnabledLibraries();
});
chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === "ghostlight-library-repair") void syncEnabledLibraries();
});

let bookmarkListenersRegistered = false;
let readingListListenersRegistered = false;
registerLibraryListeners();
chrome.permissions.onAdded.addListener(registerLibraryListeners);
chrome.permissions.onRemoved.addListener((permissions) => {
  if (permissions.permissions?.includes("bookmarks")) void clearRemovedLibrary("bookmark");
  if (permissions.permissions?.includes("readingList")) void clearRemovedLibrary("reading_list");
});

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.type !== "sync-library" && message?.type !== "clear-library") return false;
  syncLibrary(message.kind, message.type === "clear-library" ? [] : undefined)
    .then(() => sendResponse({ ok: true }))
    .catch((error) => sendResponse({ ok: false, error: error.message }));
  return true;
});

let syncTail = Promise.resolve();

export function syncLibrary(kind, replacement) {
  if (kind !== "bookmark" && kind !== "reading_list") return Promise.reject(new Error("Unknown Chrome library source."));
  syncTail = syncTail.catch(() => {}).then(() => replaceLibrarySnapshot(kind, replacement));
  return syncTail;
}

async function syncEnabledLibraries() {
  const settings = await chrome.storage.local.get([
    "mirrorBookmarks", "mirrorReadingList", "bookmarkClearPending", "reading_listClearPending"
  ]);
  if (settings.bookmarkClearPending) await retryPendingClear("bookmark");
  if (settings.reading_listClearPending) await retryPendingClear("reading_list");
  if (settings.mirrorBookmarks) {
    if (await chrome.permissions.contains({ permissions: ["bookmarks"] })) await syncLibrary("bookmark");
    else await chrome.storage.local.set({ mirrorBookmarks: false });
  }
  if (settings.mirrorReadingList) {
    if (await chrome.permissions.contains({ permissions: ["readingList"] })) await syncLibrary("reading_list");
    else await chrome.storage.local.set({ mirrorReadingList: false });
  }
}

async function clearRemovedLibrary(kind) {
  const setting = kind === "bookmark" ? "mirrorBookmarks" : "mirrorReadingList";
  const pending = `${kind}ClearPending`;
  await chrome.storage.local.set({ [setting]: false, [pending]: true });
  try {
    await syncLibrary(kind, []);
    await chrome.storage.local.set({ [pending]: false });
  } catch {
    await ensureRepairAlarm();
  }
}

async function retryPendingClear(kind) {
  const pending = `${kind}ClearPending`;
  try {
    await syncLibrary(kind, []);
    await chrome.storage.local.set({ [pending]: false });
  } catch {
    await ensureRepairAlarm();
  }
}

async function ensureRepairAlarm() {
  if (!await chrome.alarms.get("ghostlight-library-repair")) {
    await chrome.alarms.create("ghostlight-library-repair", { periodInMinutes: 15 });
  }
}

function registerLibraryListeners() {
  if (!bookmarkListenersRegistered && chrome.bookmarks) {
    chrome.bookmarks.onCreated.addListener(() => void syncLibrary("bookmark"));
    chrome.bookmarks.onRemoved.addListener(() => void syncLibrary("bookmark"));
    chrome.bookmarks.onChanged.addListener(() => void syncLibrary("bookmark"));
    chrome.bookmarks.onMoved.addListener(() => void syncLibrary("bookmark"));
    chrome.bookmarks.onChildrenReordered.addListener(() => void syncLibrary("bookmark"));
    bookmarkListenersRegistered = true;
  }
  if (!readingListListenersRegistered && chrome.readingList) {
    chrome.readingList.onEntryAdded.addListener(() => void syncLibrary("reading_list"));
    chrome.readingList.onEntryRemoved.addListener(() => void syncLibrary("reading_list"));
    chrome.readingList.onEntryUpdated.addListener(() => void syncLibrary("reading_list"));
    readingListListenersRegistered = true;
  }
}

async function replaceLibrarySnapshot(kind, replacement) {
  const key = kind === "bookmark" ? "mirrorBookmarks" : "mirrorReadingList";
  const permission = kind === "bookmark" ? "bookmarks" : "readingList";
  const settings = await chrome.storage.local.get(["controlOrigin", "deviceToken", key, `${kind}Revision`]);
  if (!settings.controlOrigin || !settings.deviceToken || (replacement === undefined && !settings[key])) return;
  if (replacement === undefined && !await chrome.permissions.contains({ permissions: [permission] })) {
    throw new Error(`Chrome ${kind === "bookmark" ? "bookmark" : "Reading List"} permission is missing.`);
  }

  const items = replacement ?? (kind === "bookmark"
    ? bookmarkItems(await chrome.bookmarks.getTree())
    : readingListItems(await chrome.readingList.query({})));
  if (items.length > 5000) throw new Error("Ghostlight library sync supports up to 5,000 items.");
  const revision = Math.max(Number(settings[`${kind}Revision`] ?? 0) + 1, Date.now());
  const body = JSON.stringify({ kind, revision, items });
  if (new TextEncoder().encode(body).byteLength > 1024 * 1024) {
    throw new Error("This Chrome library is larger than Ghostlight's 1 MiB snapshot limit.");
  }
  const response = await fetch(endpoint(settings.controlOrigin, "v1/chrome-library-snapshots"), {
    method: "PUT",
    headers: {
      "Accept": "application/json",
      "Content-Type": "application/json",
      "Authorization": `Bearer ${settings.deviceToken}`
    },
    body
  });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(payload?.error?.message ?? `Ghostlight returned HTTP ${response.status}.`);
  await chrome.storage.local.set({ [`${kind}Revision`]: revision, [`${kind}SyncedAt`]: payload.received_at });
}
