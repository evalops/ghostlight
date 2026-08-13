import assert from "node:assert/strict";
import test from "node:test";

function extensionEvent() {
  const listeners = [];
  return {
    listeners,
    addListener(listener) { listeners.push(listener); }
  };
}

test("service worker loads without optional APIs and fails closed when permission disappears", async () => {
  const stored = [];
  const onMessage = extensionEvent();
  const onRemoved = extensionEvent();
  globalThis.chrome = {
    storage: { local: {
      async setAccessLevel() {},
      async get() {
        return {
          controlOrigin: "https://ghostlight.test",
          deviceToken: "device-token",
          mirrorBookmarks: true,
          bookmarkRevision: 10
        };
      },
      async set(value) { stored.push(value); }
    } },
    runtime: { onInstalled: extensionEvent(), onStartup: extensionEvent(), onMessage },
    alarms: { onAlarm: extensionEvent(), async get() { return null; }, async create() {} },
    permissions: {
      onAdded: extensionEvent(),
      onRemoved,
      async contains() { return false; }
    }
  };
  globalThis.fetch = async () => ({ ok: true, async json() { return { received_at: "2026-08-13T12:00:00Z" }; } });

  await import(`../service-worker.js?test=${Date.now()}`);
  assert.equal(onMessage.listeners.length, 1);
  assert.equal(onRemoved.listeners.length, 1);

  const response = await new Promise((resolve) => {
    assert.equal(onMessage.listeners[0]({ type: "sync-library", kind: "bookmark" }, {}, resolve), true);
  });
  assert.equal(response.ok, false);
  assert.match(response.error, /permission is missing/);

  onRemoved.listeners[0]({ permissions: ["bookmarks"] });
  await new Promise((resolve) => setTimeout(resolve, 10));
  assert.deepEqual(stored.at(-1), { bookmarkClearPending: false });
  assert.ok(stored.some((value) => value.mirrorBookmarks === false && value.bookmarkClearPending === true));
});
