import assert from "node:assert/strict";
import test from "node:test";
import { endpoint, hostPermission, normalizeControlOrigin, safeHandoff } from "../sync-core.js";

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
