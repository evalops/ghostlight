import assert from "node:assert/strict";
import test from "node:test";

import protocol from "../protocol.js";

test("normalizeTab keeps only product tab state", () => {
  assert.deepEqual(
    protocol.normalizeTab({
      id: 17,
      title: "Example",
      url: "https://example.test/path",
      favIconUrl: "https://example.test/icon.png",
      active: true,
      status: "loading",
      audible: false,
      discarded: false,
      windowId: 2,
      index: 4,
      pendingUrl: "https://example.test/next",
    }),
    {
      id: "17",
      title: "Example",
      url: "https://example.test/path",
      favicon_url: "https://example.test/icon.png",
      active: true,
      loading: true,
      audible: false,
      discarded: false,
      window_id: 2,
      index: 4,
    },
  );
});

test("validateCommand accepts the bounded command enum", () => {
  for (const type of [
    "navigate",
    "activate_tab",
    "create_tab",
    "close_tab",
    "back",
    "forward",
    "reload",
    "stage_attachment",
    "restore_space",
  ]) {
    const command = type === "restore_space"
      ? { id: "command-1", type, space_id: "space-1", destinations: ["https://example.test/"], active_position: 0 }
      : { id: "command-1", type };
    assert.equal(protocol.validateCommand(command).type, type);
  }
  assert.throws(() => protocol.validateCommand({ id: "command-1", type: "execute_script" }), /unsupported/);
});

test("restore space validation fails before browser mutation", () => {
  assert.throws(() => protocol.validateCommand({ id: "command-1", type: "restore_space", space_id: "space-1", destinations: ["chrome://settings"], active_position: 0 }), /HTTP or HTTPS/);
  assert.throws(() => protocol.validateCommand({ id: "command-1", type: "restore_space", space_id: "space-1", destinations: [], active_position: 0 }), /bounded/);
});

test("navigation URLs are restricted to HTTP and HTTPS", () => {
  assert.equal(protocol.validateNavigationURL("https://example.test/"), "https://example.test/");
  assert.equal(protocol.validateNavigationURL("http://127.0.0.1:8000/fixture"), "http://127.0.0.1:8000/fixture");
  for (const value of ["", "file:///etc/passwd", "javascript:alert(1)", "chrome://settings"] ) {
    assert.throws(() => protocol.validateNavigationURL(value), /HTTP or HTTPS/);
  }
});

test("snapshot revision is monotonic", () => {
  const first = protocol.buildHeartbeat("session-1", 3, [{ id: 1, active: true }]);
  const second = protocol.buildHeartbeat("session-1", 4, [{ id: 1, active: true }]);
  assert.equal(first.payload.sequence, 3);
  assert.equal(second.payload.sequence, 4);
  assert.equal(second.payload.active_tab_id, "1");
});
