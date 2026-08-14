import assert from "node:assert/strict";
import test from "node:test";

import { createReconnectScheduler } from "../connection-retry.js";

test("native bridge retries use a durable alarm with bounded backoff", () => {
  const created = [];
  const cleared = [];
  const timers = [];
  const clearedTimers = [];
  const alarms = {
    create: (name, schedule) => created.push({ name, schedule }),
    clear: (name) => cleared.push(name),
  };
  const scheduler = createReconnectScheduler(
    alarms,
    "ghostlight-reconnect",
    () => 1_000,
    (callback, delay) => {
      timers.push({ callback, delay });
      return timers.length;
    },
    (timer) => clearedTimers.push(timer),
  );
  let reconnects = 0;

  assert.equal(scheduler.schedule(() => { reconnects += 1; }), 500);
  assert.equal(timers.at(-1).delay, 500);
  assert.deepEqual(created.at(-1), {
    name: "ghostlight-reconnect",
    schedule: { when: 31_000 },
  });
  timers.at(-1).callback();
  assert.equal(reconnects, 1);

  for (let attempt = 0; attempt < 20; attempt += 1) scheduler.schedule(() => {});
  assert.equal(created.at(-1).schedule.when, 31_000);

  scheduler.reset();
  assert.deepEqual(cleared, ["ghostlight-reconnect"]);
  assert.equal(clearedTimers.at(-1), 21);
  assert.equal(scheduler.schedule(() => {}), 500);
});
