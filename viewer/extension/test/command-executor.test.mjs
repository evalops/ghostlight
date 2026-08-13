import assert from "node:assert/strict";
import test from "node:test";

import { executeCommand } from "../command-executor.js";

function tabRecorder() {
  const calls = [];
  const record = (name) => async (...args) => {
    calls.push([name, ...args]);
    return { name, args };
  };
  return {
    calls,
    tabs: Object.fromEntries(["update", "create", "remove", "goBack", "goForward", "reload"].map((name) => [name, record(name)])),
  };
}

test("bounded commands dispatch to the Chrome tabs API", async () => {
  const { calls, tabs } = tabRecorder();
  const nativeRequests = [];
  const nativeRequest = async (message) => {
    nativeRequests.push(message);
    return { filename: "report.pdf" };
  };

  await executeCommand({ type: "navigate", tab_id: "7", url: "https://example.test/path" }, tabs, nativeRequest);
  await executeCommand({ type: "navigate", url: "https://example.test/active" }, tabs, nativeRequest);
  await executeCommand({ type: "activate_tab", tab_id: "8" }, tabs, nativeRequest);
  await executeCommand({ type: "create_tab", url: "https://example.test/new" }, tabs, nativeRequest);
  await executeCommand({ type: "close_tab", tab_id: "9" }, tabs, nativeRequest);
  await executeCommand({ type: "back", tab_id: "10" }, tabs, nativeRequest);
  await executeCommand({ type: "forward", tab_id: "11" }, tabs, nativeRequest);
  await executeCommand({ type: "reload", tab_id: "12" }, tabs, nativeRequest);
  await executeCommand({ type: "stage_attachment", attachment_id: "attachment-1" }, tabs, nativeRequest);

  assert.deepEqual(calls, [
    ["update", 7, { url: "https://example.test/path" }],
    ["update", { url: "https://example.test/active" }],
    ["update", 8, { active: true }],
    ["create", { url: "https://example.test/new", active: true }],
    ["remove", 9],
    ["goBack", 10],
    ["goForward", 11],
    ["reload", 12],
  ]);
  assert.deepEqual(nativeRequests, [{ operation: "stage_attachment", attachment_id: "attachment-1" }]);
});

test("executor rejects unsupported commands and unsafe navigation", async () => {
  const { tabs } = tabRecorder();
  await assert.rejects(executeCommand({ type: "navigate", url: "file:///etc/passwd" }, tabs, async () => ({})), /HTTP or HTTPS/);
  await assert.rejects(executeCommand({ type: "execute_script" }, tabs, async () => ({})), /unsupported/);
});
