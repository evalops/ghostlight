import assert from "node:assert/strict";
import test from "node:test";

import { enforceContentOnlyWindow, enforceContentOnlyWindows } from "../window-chrome.js";

test("normal Chromium windows enter content-only fullscreen", async () => {
  const updates = [];
  const windowsApi = {
    async getAll(options) {
      assert.deepEqual(options, { windowTypes: ["normal"] });
      return [
        { id: 7, type: "normal", state: "normal" },
        { id: 8, type: "normal", state: "fullscreen" },
      ];
    },
    async update(id, changes) {
      updates.push({ id, changes });
    },
  };

  await enforceContentOnlyWindows(windowsApi);

  assert.deepEqual(updates, [{ id: 7, changes: { state: "fullscreen" } }]);
});

test("non-content windows are left untouched", async () => {
  let updated = false;
  const windowsApi = { async update() { updated = true; } };

  assert.equal(await enforceContentOnlyWindow({ id: 9, type: "popup", state: "normal" }, windowsApi), false);
  assert.equal(await enforceContentOnlyWindow({ type: "normal", state: "normal" }, windowsApi), false);
  assert.equal(updated, false);
});
