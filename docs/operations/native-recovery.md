# Native recovery matrix

The recovery matrix runs six disruption scenarios with 25 cycles per scenario. Each cycle has a 15-second recovery deadline and a bounded cleanup action. The evaluator accepts a matrix only when all 150 cycles have valid source, disruption, recovery, invariant, and cleanup receipts.

The six scenarios are:

1. Network loss
2. Viewer restart
3. Chromium restart
4. Control restart
5. Lease expiry with controller transfer
6. Deterministic suspension surrogate

Calendar duration is outside this gate and does not affect the evaluator result.

## Deterministic run

Run the fixture adapter and evaluator:

```sh
tools/run-recovery-matrix.sh
```

The command writes mode-`600` receipts under `output/recovery/`:

- `matrix.json`: raw receipts for 150 cycles.
- `evaluation.json`: accepted or blocked evaluator result.

The evaluator test covers a valid matrix, recovery timeout, malformed invariant receipt, source mismatch, cleanup failure, duplicate controller ownership, a missing scenario, and an incomplete cycle set:

```sh
node tools/test-evaluate-recovery.mjs
```

## Live adapter safety

Live disruptions require these variables:

```sh
export GHOSTLIGHT_RECOVERY_MODE=live
export GHOSTLIGHT_RECOVERY_LIVE_OPT_IN=I_UNDERSTAND_THIS_IS_DISRUPTIVE
export GHOSTLIGHT_RECOVERY_TARGET_ID=session-host-123
export GHOSTLIGHT_RECOVERY_TARGET_TOKEN='<target-specific token with at least 16 characters>'
export GHOSTLIGHT_RECOVERY_ADAPTER=/absolute/path/to/recovery-adapter
tools/run-recovery-matrix.sh
```

The live runner rejects a dirty source tree, a missing executable adapter, broad target names (`all`, `default`, or `global`), short target tokens, and absent opt-in. The adapter receives one JSON request on standard input for each `disrupt`, `recover`, and `cleanup` action. The runner invokes `cleanup` in a `finally` path after each disruption attempt.

Each request contains:

- `action`, `scenario`, and cycle number
- exact `source_sha`
- one `target_id`
- `isolation_token`
- the cycle's `deadline_at`

The adapter must write one JSON receipt to standard output and exit zero. Each receipt must echo `target_id` and include `isolation_receipt`, calculated as lowercase SHA-256 over `target_id`, one zero byte, and `isolation_token`. A target mismatch blocks the cycle before its receipt can pass evaluation.

The `recover` receipt must have `status: "applied"`, `completed_at`, and these invariant receipts:

- `authoritative_session_state.passed: true`
- `controller_ownership.passed: true` and `owner_count: 1`
- `decoded_video.passed: true` and `frames_decoded_delta` greater than zero
- `accepted_input_command.passed: true` and `terminal_state: "applied"`

Each invariant requires a unique `receipt_id`. The `cleanup` receipt must have `status: "applied"` and prove `target_restored`, `disruption_absent`, and `controller_owner_count: 1`.

The adapter owns the platform-specific disruption hooks. An adapter must bind every network rule, process operation, lease action, and suspension surrogate to the supplied target ID. The cleanup action must remove only artifacts created for that target and cycle.

## Failure handling

The runner stops after the first failed live cycle, attempts cleanup, and writes the partial matrix. The evaluator then writes a blocked result. Keep both files when investigating a failure. A missing or malformed field, late recovery, source mismatch, duplicate receipt ID, failed invariant, or failed cleanup produces a nonzero exit.
