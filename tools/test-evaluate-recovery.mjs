import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const evaluator = path.join(root, "tools/evaluate-recovery.mjs");
const harness = path.join(root, "tests/acceptance/recovery.mjs");
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), "ghostlight-recovery-evaluator-"));
const inputPath = path.join(temporary, "matrix.json");
const outputPath = path.join(temporary, "evaluation.json");
const sourceSha = "a".repeat(40);
const scenarios = [
  "network-loss",
  "viewer-restart",
  "chromium-restart",
  "control-restart",
  "lease-expiry-controller-transfer",
  "suspension-surrogate",
];

const stamp = (seconds) => new Date(Date.UTC(2026, 7, 13, 0, 0, seconds)).toISOString();
const validCycle = (scenario, cycle) => ({
  cycle,
  source_receipt: {
    receipt_id: `${scenario}-${cycle}-source`,
    source_sha: sourceSha,
    target_id: "fixture-target",
    captured_at: stamp(cycle),
  },
  timestamps: {
    before: stamp(cycle),
    disrupted: stamp(cycle + 1),
    recovered: stamp(cycle + 2),
    cleanup_started: stamp(cycle + 3),
    cleaned: stamp(cycle + 4),
  },
  disruption_receipt: {
    receipt_id: `${scenario}-${cycle}-disruption`,
    scenario,
    target_id: "fixture-target",
    status: "applied",
    completed_at: stamp(cycle + 1),
  },
  recovery_receipt: {
    receipt_id: `${scenario}-${cycle}-recovery`,
    target_id: "fixture-target",
    status: "applied",
    completed_at: stamp(cycle + 2),
    deadline_at: stamp(cycle + 16),
    invariants: {
      authoritative_session_state: { passed: true, receipt_id: `${scenario}-${cycle}-session` },
      controller_ownership: { passed: true, owner_count: 1, receipt_id: `${scenario}-${cycle}-controller` },
      decoded_video: { passed: true, frames_decoded_delta: 1, receipt_id: `${scenario}-${cycle}-video` },
      accepted_input_command: { passed: true, terminal_state: "applied", receipt_id: `${scenario}-${cycle}-input` },
    },
  },
  cleanup_receipt: {
    receipt_id: `${scenario}-${cycle}-cleanup`,
    target_id: "fixture-target",
    status: "applied",
    completed_at: stamp(cycle + 4),
    invariants: {
      target_restored: true,
      disruption_absent: true,
      controller_owner_count: 1,
    },
  },
});
const validMatrix = () => ({
  schema_version: 1,
  mode: "deterministic",
  source_sha: sourceSha,
  target_id: "fixture-target",
  cycles_per_scenario: 25,
  recovery_deadline_ms: 15_000,
  scenarios: scenarios.map((scenario) => ({
    scenario,
    cycles: Array.from({ length: 25 }, (_, index) => validCycle(scenario, index + 1)),
  })),
});

const evaluate = (matrix) => {
  fs.writeFileSync(inputPath, JSON.stringify(matrix));
  return spawnSync(process.execPath, [evaluator, inputPath, sourceSha, outputPath], { encoding: "utf8" });
};
const expectBlocked = (mutate, pattern) => {
  const matrix = validMatrix();
  mutate(matrix);
  const result = evaluate(matrix);
  assert.notEqual(result.status, 0, "invalid recovery evidence unexpectedly passed");
  assert.match(result.stderr || result.stdout, pattern);
  const receipt = JSON.parse(fs.readFileSync(outputPath, "utf8"));
  assert.equal(receipt.status, "blocked");
  assert.equal(receipt.gates.passed, false);
};

try {
  const passing = evaluate(validMatrix());
  assert.equal(passing.status, 0, passing.stderr || passing.stdout);
  const receipt = JSON.parse(fs.readFileSync(outputPath, "utf8"));
  assert.equal(receipt.status, "accepted");
  assert.equal(receipt.total_cycles, 150);
  assert.equal(receipt.gates.passed, true);

  expectBlocked((matrix) => {
    matrix.scenarios[0].cycles[0].recovery_receipt.completed_at = stamp(18);
  }, /deadline/i);
  expectBlocked((matrix) => {
    delete matrix.scenarios[1].cycles[0].recovery_receipt.invariants.decoded_video.receipt_id;
  }, /malformed|decoded video/i);
  expectBlocked((matrix) => {
    matrix.scenarios[2].cycles[0].source_receipt.source_sha = "b".repeat(40);
  }, /source/i);
  expectBlocked((matrix) => {
    matrix.scenarios[3].cycles[0].cleanup_receipt.status = "failed";
  }, /cleanup/i);
  expectBlocked((matrix) => {
    matrix.scenarios[4].cycles[0].recovery_receipt.invariants.controller_ownership.owner_count = 2;
  }, /controller/i);
  expectBlocked((matrix) => {
    matrix.scenarios.pop();
  }, /six recovery scenarios|scenario/i);
  expectBlocked((matrix) => {
    matrix.scenarios[0].cycles.pop();
  }, /25 cycles|cycle/i);

  const broadTarget = spawnSync(process.execPath, [harness, inputPath, sourceSha, "all", "deterministic"], { encoding: "utf8" });
  assert.notEqual(broadTarget.status, 0);
  assert.match(broadTarget.stderr || broadTarget.stdout, /target ID/i);

  const liveEnvironment = { ...process.env };
  delete liveEnvironment.GHOSTLIGHT_RECOVERY_LIVE_OPT_IN;
  delete liveEnvironment.GHOSTLIGHT_RECOVERY_ADAPTER;
  delete liveEnvironment.GHOSTLIGHT_RECOVERY_TARGET_TOKEN;
  const liveWithoutOptIn = spawnSync(
    process.execPath,
    [harness, inputPath, sourceSha, "fixture-target", "live"],
    { encoding: "utf8", env: liveEnvironment },
  );
  assert.notEqual(liveWithoutOptIn.status, 0);
  assert.match(liveWithoutOptIn.stderr || liveWithoutOptIn.stdout, /live recovery requires/i);
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
