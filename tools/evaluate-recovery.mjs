import fs from "node:fs";

const [matrixPath, expectedSourceSha, outputPath] = process.argv.slice(2);
if (!matrixPath || !expectedSourceSha || !outputPath) {
  throw new Error("usage: evaluate-recovery.mjs <matrix-json> <expected-source-sha> <output-json>");
}

const REQUIRED_SCENARIOS = [
  "network-loss",
  "viewer-restart",
  "chromium-restart",
  "control-restart",
  "lease-expiry-controller-transfer",
  "suspension-surrogate",
];
const SOURCE_PATTERN = /^(?:[0-9a-f]{40}|[0-9a-f]{64})$/;
const REQUIRED_INVARIANTS = [
  "authoritative_session_state",
  "controller_ownership",
  "decoded_video",
  "accepted_input_command",
];

const failures = [];
const receiptIds = new Set();
const fail = (message) => failures.push(message);
const isObject = (value) => value !== null && typeof value === "object" && !Array.isArray(value);
const isTimestamp = (value) => typeof value === "string" && Number.isFinite(Date.parse(value));
const timestamp = (value) => isTimestamp(value) ? Date.parse(value) : Number.NaN;
const requireReceiptId = (receipt, label) => {
  if (!isObject(receipt) || typeof receipt.receipt_id !== "string" || receipt.receipt_id.length === 0) {
    fail(`${label} is malformed: receipt_id is required`);
    return;
  }
  if (receiptIds.has(receipt.receipt_id)) fail(`${label} reuses receipt_id ${receipt.receipt_id}`);
  receiptIds.add(receipt.receipt_id);
};

let matrix;
try {
  matrix = JSON.parse(fs.readFileSync(matrixPath, "utf8"));
} catch (error) {
  fail(`malformed recovery matrix: ${error.message}`);
  matrix = {};
}

if (!SOURCE_PATTERN.test(expectedSourceSha)) fail("expected source SHA must be a 40- or 64-character lowercase hexadecimal commit identifier");
if (matrix.schema_version !== 1) fail("recovery matrix schema_version must be 1");
if (!new Set(["deterministic", "live"]).has(matrix.mode)) fail("recovery matrix mode must be deterministic or live");
if (matrix.mode !== "live") fail("only live recovery receipts can be accepted; deterministic evidence is test-only");
if (typeof matrix.live_adapter !== "string" || !matrix.live_adapter.startsWith("/")) fail("live recovery receipts require an absolute adapter identity");
if (matrix.source_sha !== expectedSourceSha) fail("matrix source SHA does not match the expected source SHA");
if (typeof matrix.target_id !== "string" || matrix.target_id.length === 0) fail("matrix target_id is required");
if (matrix.cycles_per_scenario !== 25) fail("recovery matrix must use exactly 25 cycles per scenario");
if (matrix.recovery_deadline_ms !== 15_000) fail("recovery matrix must use a 15-second recovery deadline");

const scenarioEntries = Array.isArray(matrix.scenarios) ? matrix.scenarios : [];
const scenarioNames = scenarioEntries.map((entry) => entry?.scenario);
if (scenarioEntries.length !== REQUIRED_SCENARIOS.length
  || new Set(scenarioNames).size !== REQUIRED_SCENARIOS.length
  || REQUIRED_SCENARIOS.some((scenario) => !scenarioNames.includes(scenario))) {
  fail("matrix must contain each of the six recovery scenarios exactly once");
}

let totalCycles = 0;
for (const entry of scenarioEntries) {
  const scenario = entry?.scenario ?? "unknown";
  const cycles = Array.isArray(entry?.cycles) ? entry.cycles : [];
  if (cycles.length !== 25) fail(`${scenario} must contain exactly 25 cycles`);
  const cycleNumbers = cycles.map((cycle) => cycle?.cycle);
  if (cycles.length === 25 && cycleNumbers.some((cycle, index) => cycle !== index + 1)) {
    fail(`${scenario} cycle numbers must be the fixed sequence 1 through 25`);
  }
  totalCycles += cycles.length;

  for (const cycle of cycles) {
    const label = `${scenario} cycle ${cycle?.cycle ?? "unknown"}`;
    const source = cycle?.source_receipt;
    const disruption = cycle?.disruption_receipt;
    const recovery = cycle?.recovery_receipt;
    const cleanup = cycle?.cleanup_receipt;
    requireReceiptId(source, `${label} source receipt`);
    requireReceiptId(disruption, `${label} disruption receipt`);
    requireReceiptId(recovery, `${label} recovery receipt`);
    requireReceiptId(cleanup, `${label} cleanup receipt`);

    if (source?.source_sha !== expectedSourceSha || source?.target_id !== matrix.target_id || !isTimestamp(source?.captured_at)) {
      fail(`${label} source receipt is malformed or does not match source and target`);
    }
    if (disruption?.scenario !== scenario || disruption?.target_id !== matrix.target_id
      || disruption?.adapter_receipt !== true || disruption?.status !== "applied" || !isTimestamp(disruption?.completed_at)) {
      fail(`${label} disruption receipt is malformed or non-terminal`);
    }
    if (recovery?.target_id !== matrix.target_id || recovery?.status !== "applied"
      || recovery?.adapter_receipt !== true || !isTimestamp(recovery?.completed_at) || !isTimestamp(recovery?.deadline_at)) {
      fail(`${label} recovery receipt is malformed or non-terminal`);
    }
    if (cleanup?.target_id !== matrix.target_id || cleanup?.adapter_receipt !== true || cleanup?.status !== "applied" || !isTimestamp(cleanup?.completed_at)) {
      fail(`${label} cleanup receipt is malformed or failed`);
    }

    const times = cycle?.timestamps;
    const ordered = [times?.before, times?.disrupted, times?.recovered, times?.cleanup_started, times?.cleaned];
    if (ordered.some((value) => !isTimestamp(value))
      || ordered.slice(1).some((value, index) => timestamp(value) < timestamp(ordered[index]))) {
      fail(`${label} timestamps are missing or out of order`);
    }
    if (isTimestamp(times?.before) && isTimestamp(recovery?.completed_at)
      && timestamp(recovery.completed_at) - timestamp(times.before) > matrix.recovery_deadline_ms) {
      fail(`${label} exceeded the 15-second recovery deadline`);
    }
    if (isTimestamp(recovery?.completed_at) && isTimestamp(recovery?.deadline_at)
      && timestamp(recovery.completed_at) > timestamp(recovery.deadline_at)) {
      fail(`${label} recovery completed after its explicit deadline`);
    }
    if (isTimestamp(recovery?.completed_at) && isTimestamp(cleanup?.completed_at)
      && timestamp(cleanup.completed_at) < timestamp(recovery.completed_at)) {
      fail(`${label} cleanup completed before recovery`);
    }

    const invariants = recovery?.invariants;
    for (const name of REQUIRED_INVARIANTS) {
      const invariant = invariants?.[name];
      requireReceiptId(invariant, `${label} ${name.replaceAll("_", " ")} invariant`);
      if (invariant?.passed !== true) fail(`${label} ${name.replaceAll("_", " ")} invariant did not pass`);
    }
    if (invariants?.controller_ownership?.owner_count !== 1) fail(`${label} controller ownership is not singular`);
    if (!(invariants?.decoded_video?.frames_decoded_delta > 0)) fail(`${label} decoded video invariant lacks a positive frame delta`);
    if (invariants?.accepted_input_command?.terminal_state !== "applied") fail(`${label} input command lacks an applied terminal receipt`);

    if (cleanup?.invariants?.target_restored !== true
      || cleanup?.invariants?.disruption_absent !== true
      || cleanup?.invariants?.controller_owner_count !== 1) {
      fail(`${label} cleanup invariants failed`);
    }
  }
}

const result = {
  schema_version: 1,
  evaluated_at: new Date().toISOString(),
  status: failures.length === 0 ? "accepted" : "blocked",
  source_sha: matrix.source_sha ?? null,
  expected_source_sha: expectedSourceSha,
  target_id: matrix.target_id ?? null,
  mode: matrix.mode ?? null,
  scenario_count: scenarioEntries.length,
  total_cycles: totalCycles,
  gates: {
    live_receipts: matrix.mode === "live",
    exact_source: matrix.source_sha === expectedSourceSha,
    fixed_matrix: scenarioEntries.length === 6 && totalCycles === 150,
    bounded_deadlines: matrix.recovery_deadline_ms === 15_000,
    terminal_recovery_receipts: failures.every((failure) => !/recovery receipt|deadline|input command|decoded video|controller/i.test(failure)),
    cleanup_receipts: failures.every((failure) => !/cleanup/i.test(failure)),
    passed: failures.length === 0,
  },
  failures,
};

fs.writeFileSync(outputPath, `${JSON.stringify(result, null, 2)}\n`, { mode: 0o600 });
if (failures.length > 0) {
  process.stderr.write(`recovery evidence blocked: ${failures.join("; ")}\n`);
  process.exitCode = 1;
} else {
  process.stdout.write(`recovery evidence accepted: ${totalCycles} bounded cycles\n`);
}
