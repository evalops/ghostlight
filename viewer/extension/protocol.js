const allowedCommandTypes = new Set([
  "navigate",
  "activate_tab",
  "create_tab",
  "close_tab",
  "back",
  "forward",
  "reload",
  "stage_attachment",
]);

function normalizeTab(tab) {
  return {
    id: String(tab.id),
    title: typeof tab.title === "string" ? tab.title : "",
    url: typeof tab.url === "string" ? tab.url : "",
    favicon_url: typeof tab.favIconUrl === "string" ? tab.favIconUrl : "",
    active: tab.active === true,
    loading: tab.status === "loading",
    audible: tab.audible === true,
    discarded: tab.discarded === true,
    window_id: Number.isInteger(tab.windowId) ? tab.windowId : 0,
    index: Number.isInteger(tab.index) ? tab.index : 0,
  };
}

function validateNavigationURL(value) {
  let parsed;
  try {
    parsed = new URL(value);
  } catch {
    throw new Error("navigation requires an absolute HTTP or HTTPS URL");
  }
  if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
    throw new Error("navigation requires an absolute HTTP or HTTPS URL");
  }
  return parsed.href;
}

function validateCommand(command) {
  if (!command || typeof command !== "object" || typeof command.id !== "string" || command.id === "") {
    throw new Error("command requires an id");
  }
  if (!allowedCommandTypes.has(command.type)) {
    throw new Error(`unsupported command type: ${String(command.type)}`);
  }
  return command;
}

function buildHeartbeat(sessionID, sequence, tabs) {
  const normalized = tabs.map(normalizeTab);
  return {
    operation: "heartbeat",
    session_id: sessionID,
    payload: {
      session_id: sessionID,
      sequence,
      runtime_state: "ready",
      active_tab_id: normalized.find((tab) => tab.active)?.id ?? null,
      tabs: normalized,
      agent_version: chromeRuntimeVersion(),
    },
  };
}

function chromeRuntimeVersion() {
  if (typeof chrome !== "undefined" && chrome.runtime?.getManifest) {
    return chrome.runtime.getManifest().version;
  }
  return "test";
}

const protocol = { buildHeartbeat, normalizeTab, validateCommand, validateNavigationURL };

export { buildHeartbeat, normalizeTab, validateCommand, validateNavigationURL };
export default protocol;
