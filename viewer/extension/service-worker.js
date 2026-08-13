import { buildHeartbeat, validateCommand, validateNavigationURL } from "./protocol.js";
import { executeCommand } from "./command-executor.js";

const nativeHost = "org.evalops.ghostlight.browser_agent";
const heartbeatAlarm = "ghostlight-heartbeat";
const heartbeatMinutes = 0.5;
const commandPollMilliseconds = 1000;
const reconnectMaximumMilliseconds = 30000;

let nativePort;
let nativeQueue = Promise.resolve();
let sessionID;
let sequence = 0;
let reconnectAttempt = 0;
let pollTimer;
let syncTimer;

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
  clearTimeout(pollTimer);
  nativePort = chrome.runtime.connectNative(nativeHost);
  nativePort.onDisconnect.addListener(() => {
    nativePort = undefined;
    sessionID = undefined;
    scheduleReconnect();
  });
  try {
    const bootstrap = await nativeRequest({ operation: "bootstrap" });
    if (typeof bootstrap.session_id !== "string" || bootstrap.session_id === "") {
      throw new Error("bridge bootstrap omitted session_id");
    }
    sessionID = bootstrap.session_id;
    reconnectAttempt = 0;
    await publishSnapshot();
    schedulePoll(0);
  } catch {
    nativePort?.disconnect();
  }
}

function scheduleReconnect() {
  reconnectAttempt += 1;
  const delay = Math.min(500 * (2 ** (reconnectAttempt - 1)), reconnectMaximumMilliseconds);
  setTimeout(connect, delay);
}

async function publishSnapshot() {
  if (!sessionID || !nativePort) return;
  const tabs = await chrome.tabs.query({});
  sequence += 1;
  await nativeRequest(buildHeartbeat(sessionID, sequence, tabs));
}

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
      try {
        const result = await executeCommand(command, chrome.tabs, nativeRequest);
        await nativeRequest({
          operation: "ack",
          command_id: command.id,
          payload: { status: "ok", result },
        });
      } catch (error) {
        await nativeRequest({
          operation: "ack",
          command_id: command.id,
          payload: { status: "failed", error: String(error?.message || error) },
        });
      }
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
  if (alarm.name === heartbeatAlarm) publishSnapshot().catch(() => {});
});
chrome.alarms.create(heartbeatAlarm, { periodInMinutes: heartbeatMinutes });
connect();
