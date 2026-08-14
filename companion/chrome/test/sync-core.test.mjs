import assert from "node:assert/strict";
import test from "node:test";
import { bookmarkItems, clearPendingDelivery, endpoint, hostPermission, normalizeControlOrigin, pendingDelivery, readingListItems, safeHandoff, safeHandoffs } from "../sync-core.js";

test("normalizes a scoped control origin", () => {
  assert.equal(normalizeControlOrigin(" https://ghostlight.test/base/ "), "https://ghostlight.test/base");
  assert.equal(endpoint("https://ghostlight.test/base", "/v1/chrome-handoffs"), "https://ghostlight.test/base/v1/chrome-handoffs");
  assert.equal(hostPermission("https://ghostlight.test/base"), "https://ghostlight.test/*");
  assert.throws(() => normalizeControlOrigin("https://user:pass@ghostlight.test"), /without credentials/);
});

test("accepts only an explicitly selected safe web tab", () => {
  assert.deepEqual(safeHandoff({ title: " Work ", url: "https://example.test/path?q=one" }), {
    title: "Work", url: "https://example.test/path?q=one"
  });
  assert.throws(() => safeHandoff({ incognito: true, url: "https://example.test" }), /Incognito/);
  assert.throws(() => safeHandoff({ url: "chrome://settings" }), /Only HTTP or HTTPS/);
  assert.throws(() => safeHandoff({ url: "https://example.test/#secret" }), /fragments/);
  assert.throws(() => safeHandoff({ url: "https://example.test/callback?access_token=secret" }), /credential/);
});

test("preserves window order and fails an entire unsafe batch", () => {
  assert.deepEqual(safeHandoffs([
    { title: "One", url: "https://one.test/" },
    { title: "Two", url: "https://two.test/" }
  ]).map((item) => item.title), ["One", "Two"]);
  assert.throws(() => safeHandoffs([
    { url: "https://safe.test/" },
    { url: "https://unsafe.test/?token=secret" }
  ]), /credential/);
});

test("preserves bookmark hierarchy and Reading List state", () => {
  assert.deepEqual(bookmarkItems([{ id: "0", title: "root", children: [
    { id: "1", parentId: "0", title: "Docs", url: "https://docs.test/" }
  ] }]), [
    { external_id: "0", parent_external_id: "", title: "root", position: 0 },
    { external_id: "1", parent_external_id: "0", title: "Docs", url: "https://docs.test/", position: 0 }
  ]);
  assert.deepEqual(readingListItems([{ title: "Later", url: "https://later.test/", hasBeenRead: true }]), [
    { external_id: "https://later.test/", title: "Later", url: "https://later.test/", position: 0, read: true }
  ]);
  assert.equal(bookmarkItems([{ id: "unsafe", url: "chrome://settings" }]).length, 0);
  assert.equal(readingListItems([{ url: "https://later.test/?token=secret" }]).length, 0);
});

test("reuses an idempotency key until a delivery receives a response", async () => {
  const values = {};
  const storage = {
    async get(key) { return { [key]: values[key] }; },
    async set(update) { Object.assign(values, update); },
    async remove(key) { delete values[key]; }
  };
  const body = { title: "Work", url: "https://example.test/continue" };
  const first = await pendingDelivery(storage, "v1/chrome-handoffs", body, () => "first-key");
  const retry = await pendingDelivery(storage, "v1/chrome-handoffs", body, () => "second-key");
  assert.deepEqual(retry, first);
  assert.doesNotMatch(first.fingerprint, /Work|example/);

  await clearPendingDelivery(storage, first);
  const next = await pendingDelivery(storage, "v1/chrome-handoffs", body, () => "next-key");
  assert.equal(next.key, "next-key");
  assert.notEqual(next.key, first.key);
});
