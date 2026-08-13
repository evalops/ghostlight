import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import fs from "node:fs";

const SCENARIOS = [
  "network-loss",
  "viewer-restart",
  "chromium-restart",
  "control-restart",
  "lease-expiry-controller-transfer",
  "suspension-surrogate",
];
const CYCLES = 25;
const RECOVERY_DEADLINE_MS = 15_000;
const LIVE_OPT_IN = "I_UNDERSTAND_THIS_IS_DISRUPTIVE";
const SOURCE_PATTERN = /^(?:[0-9a-f]{40}|[0-9a-f]{64})$/;
const TARGET_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._:-]{2,127}$/;

if (process.argv.includes("--self-test")) {
  if (SCENARIOS.length !== 6 || CYCLES !== 25 || RECOVERY_DEADLINE_MS !== 15_000) {
    throw new Error("bounded recovery constants changed unexpectedly");
  }
  process.stdout.write(`${JSON.stringify({ recovery_harness_self_test: "passed" })}\n`);
  process.exit(0);
}

const [outputPath, sourceSha, targetId, mode = "deterministic"] = process.argv.slice(2);
if (!outputPath || !sourceSha || !targetId || !new Set(["deterministic", "live"]).has(mode)) {
  throw new Error("usage: recovery.mjs <output-json> <source-sha> <target-id> [deterministic|live]");
}
if (!SOURCE_PATTERN.test(sourceSha)) throw new Error("source SHA must be a 40- or 64-character lowercase hexadecimal commit identifier");
if (!TARGET_PATTERN.test(targetId) || new Set(["all", "default", "global"]).has(targetId.toLowerCase())) {
  throw new Error("target ID must identify one isolated runtime and cannot be all, default, or global");
}

const adapterPath = process.env.GHOSTLIGHT_RECOVERY_ADAPTER ?? "";
const isolationToken = process.env.GHOSTLIGHT_RECOVERY_TARGET_TOKEN ?? "";
if (mode === "live") {
  if (process.env.GHOSTLIGHT_RECOVERY_LIVE_OPT_IN !== LIVE_OPT_IN) {
    throw new Error(`live recovery requires GHOSTLIGHT_RECOVERY_LIVE_OPT_IN=${LIVE_OPT_IN}`);
  }
  if (!adapterPath || !fs.existsSync(adapterPath)) throw new Error("live recovery requires an existing GHOSTLIGHT_RECOVERY_ADAPTER");
  if (isolationToken.length < 16) throw new Error("live recovery requires a target-specific GHOSTLIGHT_RECOVERY_TARGET_TOKEN of at least 16 characters");
}

const now = () => new Date().toISOString();
const receiptId = (scenario, cycle, phase) => `${scenario}-${cycle}-${phase}`;
const isolationReceipt = createHash("sha256").update(`${targetId}\0${isolationToken}`).digest("hex");
const deterministicAction = (action, scenario, cycle, deadlineAt) => {
  const completedAt = now();
  if (action === "disrupt") {
    return {
      receipt_id: receiptId(scenario, cycle, "disruption"),
      scenario,
      target_id: targetId,
      isolation_receipt: isolationReceipt,
      status: "applied",
      completed_at: completedAt,
    };
  }
  if (action === "recover") {
    return {
      receipt_id: receiptId(scenario, cycle, "recovery"),
      target_id: targetId,
      isolation_receipt: isolationReceipt,
      status: "applied",
      completed_at: completedAt,
      deadline_at: deadlineAt,
      invariants: {
        authoritative_session_state: { passed: true, receipt_id: receiptId(scenario, cycle, "session-state") },
        controller_ownership: { passed: true, owner_count: 1, receipt_id: receiptId(scenario, cycle, "controller") },
        decoded_video: { passed: true, frames_decoded_delta: 1, receipt_id: receiptId(scenario, cycle, "decoded-video") },
        accepted_input_command: { passed: true, terminal_state: "applied", receipt_id: receiptId(scenario, cycle, "input-command") },
      },
    };
  }
  return {
    receipt_id: receiptId(scenario, cycle, "cleanup"),
    target_id: targetId,
    isolation_receipt: isolationReceipt,
    status: "applied",
    completed_at: completedAt,
    invariants: {
      target_restored: true,
      disruption_absent: true,
      controller_owner_count: 1,
    },
  };
};

const runAction = (action, scenario, cycle, deadlineAt, timeoutMs) => {
  if (mode === "deterministic") return deterministicAction(action, scenario, cycle, deadlineAt);
  const request = {
    schema_version: 1,
    action,
    scenario,
    cycle,
    target_id: targetId,
    isolation_token: isolationToken,
    source_sha: sourceSha,
    deadline_at: deadlineAt,
  };
  const result = spawnSync(adapterPath, [], {
    encoding: "utf8",
    input: `${JSON.stringify(request)}\n`,
    timeout: Math.max(1, timeoutMs),
    killSignal: "SIGKILL",
  });
  if (result.error) throw new Error(`${action} adapter failed: ${result.error.message}`);
  if (result.status !== 0) throw new Error(`${action} adapter exited ${result.status}: ${(result.stderr || "").trim()}`);
  let receipt;
  try {
    receipt = JSON.parse(result.stdout);
  } catch (error) {
    throw new Error(`${action} adapter returned malformed JSON: ${error.message}`);
  }
  if (receipt.target_id !== targetId || receipt.isolation_receipt !== isolationReceipt) {
    throw new Error(`${action} adapter receipt did not prove target isolation`);
  }
  if (action === "recover") receipt.deadline_at = deadlineAt;
  return receipt;
};

const matrix = {
  schema_version: 1,
  mode,
  source_sha: sourceSha,
  target_id: targetId,
  cycles_per_scenario: CYCLES,
  recovery_deadline_ms: RECOVERY_DEADLINE_MS,
  scenarios: [],
};
let harnessFailure = null;

outer: for (const scenario of SCENARIOS) {
  const scenarioReceipt = { scenario, cycles: [] };
  matrix.scenarios.push(scenarioReceipt);
  for (let cycle = 1; cycle <= CYCLES; cycle += 1) {
    const before = now();
    const deadlineAt = new Date(Date.parse(before) + RECOVERY_DEADLINE_MS).toISOString();
    const cycleReceipt = {
      cycle,
      source_receipt: {
        receipt_id: receiptId(scenario, cycle, "source"),
        source_sha: sourceSha,
        target_id: targetId,
        captured_at: before,
      },
      timestamps: { before },
    };
    scenarioReceipt.cycles.push(cycleReceipt);
    try {
      cycleReceipt.disruption_receipt = runAction("disrupt", scenario, cycle, deadlineAt, RECOVERY_DEADLINE_MS);
      cycleReceipt.timestamps.disrupted = cycleReceipt.disruption_receipt.completed_at ?? now();
      const remainingMs = Date.parse(deadlineAt) - Date.now();
      if (remainingMs <= 0) throw new Error("cycle exhausted its deadline before recovery observation");
      cycleReceipt.recovery_receipt = runAction("recover", scenario, cycle, deadlineAt, remainingMs);
      cycleReceipt.timestamps.recovered = cycleReceipt.recovery_receipt.completed_at ?? now();
    } catch (error) {
      harnessFailure = `${scenario} cycle ${cycle}: ${error.message}`;
      cycleReceipt.error = harnessFailure;
      cycleReceipt.timestamps.disrupted ??= now();
      cycleReceipt.timestamps.recovered ??= now();
    } finally {
      cycleReceipt.timestamps.cleanup_started = now();
      try {
        cycleReceipt.cleanup_receipt = runAction("cleanup", scenario, cycle, deadlineAt, RECOVERY_DEADLINE_MS);
      } catch (error) {
        harnessFailure = `${harnessFailure ? `${harnessFailure}; ` : ""}${scenario} cycle ${cycle} cleanup: ${error.message}`;
        cycleReceipt.cleanup_receipt = {
          receipt_id: receiptId(scenario, cycle, "cleanup-failed"),
          target_id: targetId,
          status: "failed",
          completed_at: now(),
          error: error.message,
          invariants: { target_restored: false, disruption_absent: false, controller_owner_count: null },
        };
      }
      cycleReceipt.timestamps.cleaned = cycleReceipt.cleanup_receipt.completed_at ?? now();
    }
    if (harnessFailure) break outer;
  }
}

fs.writeFileSync(outputPath, `${JSON.stringify(matrix, null, 2)}\n`, { mode: 0o600 });
if (harnessFailure) {
  process.stderr.write(`recovery harness blocked: ${harnessFailure}\n`);
  process.exitCode = 1;
} else {
  process.stdout.write(`recovery matrix captured: ${SCENARIOS.length * CYCLES} cycles\n`);
}
