import { completeCommand } from "./command-completion.js";
import { createReconnectScheduler } from "./connection-retry.js";
import { executeCommand } from "./command-executor.js";
import { buildHeartbeat, validateCommand } from "./protocol.js";
import { createSnapshotPublisher } from "./snapshot-coalescer.js";
import { enforceContentOnlyWindow, enforceContentOnlyWindows } from "./window-chrome.js";

const nativeHost = "org.evalops.ghostlight.browser_agent";
const heartbeatAlarm = "ghostlight-heartbeat";
const reconnectAlarm = "ghostlight-reconnect";
const heartbeatMinutes = 0.5;
const commandPollMilliseconds = 1000;

let nativePort;
let connectInFlight = false;
let nativeQueue = Promise.resolve();
let sessionID;
let sequence = 0;
let pollTimer;
let syncTimer;
const reconnectScheduler = createReconnectScheduler(chrome.alarms, reconnectAlarm);

function nativeRequest(message) {
  nativeQueue = nativeQueue.catch(() => {}).then(() => new Promise((resolve, reject) => {
    if (!nativePort) {
      reject(new Error("native host is disconnected"));
      return;
    }
    const onMessage = (response) => {
      nativePort.onMessage.removeListener(onMessage);
      nativePort.onDisconnect.removeListener(onDisconnect);
      if (!response?.ok) {
        reject(new Error(response?.error || "native host rejected the request"));
        return;
      }
      resolve(response.payload ?? {});
    };
    const onDisconnect = () => {
      nativePort?.onMessage.removeListener(onMessage);
      reject(new Error("native host disconnected"));
    };
    nativePort.onMessage.addListener(onMessage);
    nativePort.onDisconnect.addListener(onDisconnect);
    nativePort.postMessage(message);
  }));
  return nativeQueue;
}

async function connect() {
  if (nativePort || connectInFlight) return;
  connectInFlight = true;
  clearTimeout(pollTimer);
  let port;
  try {
    port = chrome.runtime.connectNative(nativeHost);
    nativePort = port;
    port.onDisconnect.addListener(() => {
      if (nativePort !== port) return;
      nativePort = undefined;
      sessionID = undefined;
      reconnectScheduler.schedule(() => void connect());
    });
    const bootstrap = await nativeRequest({ operation: "bootstrap" });
    if (typeof bootstrap.session_id !== "string" || bootstrap.session_id === "") {
      throw new Error("bridge bootstrap omitted session_id");
    }
    sessionID = bootstrap.session_id;
    reconnectScheduler.reset();
    await publishSnapshot();
    schedulePoll(0);
  } catch (error) {
    console.error("Ghostlight native bridge connection failed", error);
    if (nativePort === port) {
      nativePort = undefined;
      sessionID = undefined;
      port?.disconnect();
      reconnectScheduler.schedule(() => void connect());
    } else if (!port) {
      reconnectScheduler.schedule(() => void connect());
    }
  } finally {
    connectInFlight = false;
  }
}

const publishSnapshot = createSnapshotPublisher(async () => {
  if (!sessionID || !nativePort) return;
  const tabs = await chrome.tabs.query({});
  sequence += 1;
  await nativeRequest(buildHeartbeat(sessionID, sequence, tabs));
});

function scheduleSnapshot() {
  clearTimeout(syncTimer);
  syncTimer = setTimeout(() => publishSnapshot().catch(() => {}), 75);
}

function schedulePoll(delay = commandPollMilliseconds) {
  clearTimeout(pollTimer);
  pollTimer = setTimeout(pollCommands, delay);
}

async function pollCommands() {
  if (!sessionID || !nativePort) return;
  try {
    const response = await nativeRequest({ operation: "poll", session_id: sessionID, after: 0 });
    for (const rawCommand of response.commands ?? []) {
      const command = validateCommand(rawCommand);
      await completeCommand(
        command,
        chrome.storage.local,
        (value) => executeCommand(value, chrome.tabs, nativeRequest),
        (commandID, payload) => nativeRequest({ operation: "ack", command_id: commandID, payload }),
      );
    }
    if ((response.commands ?? []).length > 0) await publishSnapshot();
  } catch {
    // Native-port disconnect handling owns reconnection.
  } finally {
    if (nativePort) schedulePoll();
  }
}

for (const event of [
  chrome.tabs.onActivated,
  chrome.tabs.onAttached,
  chrome.tabs.onCreated,
  chrome.tabs.onDetached,
  chrome.tabs.onMoved,
  chrome.tabs.onRemoved,
  chrome.tabs.onReplaced,
  chrome.tabs.onUpdated,
]) {
  event.addListener(scheduleSnapshot);
}
chrome.webNavigation.onCommitted.addListener((details) => {
  if (details.frameId === 0) scheduleSnapshot();
});
chrome.webNavigation.onCompleted.addListener((details) => {
  if (details.frameId === 0) scheduleSnapshot();
});
chrome.webNavigation.onErrorOccurred.addListener((details) => {
  if (details.frameId === 0) scheduleSnapshot();
});
chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === reconnectAlarm) {
    void connect();
  } else if (alarm.name === heartbeatAlarm) {
    publishSnapshot().catch(() => {});
  }
});
chrome.alarms.create(heartbeatAlarm, { periodInMinutes: heartbeatMinutes });
void connect();
chrome.windows.onCreated.addListener((window) => {
  enforceContentOnlyWindow(window, chrome.windows).catch(() => {});
});
enforceContentOnlyWindows(chrome.windows).catch(() => {});
