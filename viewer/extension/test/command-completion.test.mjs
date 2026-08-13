import assert from "node:assert/strict";
import test from "node:test";

import { completeCommand } from "../command-completion.js";

function memoryStorage() {
  const values = {};
  return {
    values,
    async get(key) { return { [key]: values[key] }; },
    async set(update) { Object.assign(values, update); },
    async remove(key) { delete values[key]; },
  };
}

test("lost acknowledgment retries without replaying the browser command", async () => {
  const storage = memoryStorage();
  let executions = 0;
  let acknowledgments = 0;
  const execute = async () => { executions += 1; return { tab_id: 42 }; };
  const acknowledge = async () => {
    acknowledgments += 1;
    if (acknowledgments === 1) throw new Error("connection lost");
  };
  const command = { id: "command-1", type: "create_tab" };

  await assert.rejects(completeCommand(command, storage, execute, acknowledge), /connection lost/);
  await completeCommand(command, storage, execute, acknowledge);

  assert.equal(executions, 1);
  assert.equal(acknowledgments, 2);
  assert.deepEqual(storage.values, {});
});

test("failed execution is persisted before acknowledgment", async () => {
  const storage = memoryStorage();
  let received;
  await completeCommand(
    { id: "command-2", type: "reload" },
    storage,
    async () => { throw new Error("tab disappeared"); },
    async (_id, completion) => { received = completion; },
  );
  assert.deepEqual(received, { status: "failed", error: "tab disappeared" });
});
