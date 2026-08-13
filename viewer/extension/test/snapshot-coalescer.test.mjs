import assert from "node:assert/strict";
import test from "node:test";

import { createSnapshotPublisher } from "../snapshot-coalescer.js";

test("snapshot requests coalesce while one heartbeat is in flight", async () => {
  const releases = [];
  let publishes = 0;
  const request = createSnapshotPublisher(async () => {
    publishes += 1;
    await new Promise((resolve) => releases.push(resolve));
  });

  const first = request();
  request();
  request();
  assert.equal(publishes, 1);
  releases.shift()();
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(publishes, 2);
  releases.shift()();
  await first;
});
