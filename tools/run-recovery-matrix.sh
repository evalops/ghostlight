#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${GHOSTLIGHT_RECOVERY_MODE:-}"
OUTPUT_DIR="${GHOSTLIGHT_RECOVERY_OUTPUT_DIR:-$ROOT_DIR/output/recovery}"
SOURCE_SHA="$(git -C "$ROOT_DIR" rev-parse HEAD)"
TARGET_ID="${GHOSTLIGHT_RECOVERY_TARGET_ID:-deterministic-fixture}"
TARGET_TOKEN="${GHOSTLIGHT_RECOVERY_TARGET_TOKEN:-}"
RAW_RECEIPT="$OUTPUT_DIR/matrix.json"
EVALUATION_RECEIPT="$OUTPUT_DIR/evaluation.json"

[[ "$MODE" == deterministic || "$MODE" == live ]] || {
  printf 'GHOSTLIGHT_RECOVERY_MODE is required and must be deterministic or live\n' >&2
  exit 1
}
command -v node >/dev/null 2>&1 || { printf 'Node.js is required\n' >&2; exit 1; }

if [[ "$MODE" == live ]]; then
  [[ "${GHOSTLIGHT_RECOVERY_LIVE_OPT_IN:-}" == I_UNDERSTAND_THIS_IS_DISRUPTIVE ]] || {
    printf 'live recovery requires explicit disruptive opt-in\n' >&2
    exit 1
  }
  [[ -n "${GHOSTLIGHT_RECOVERY_TARGET_ID:-}" ]] || {
    printf 'live recovery requires one explicit GHOSTLIGHT_RECOVERY_TARGET_ID\n' >&2
    exit 1
  }
  [[ -n "${GHOSTLIGHT_RECOVERY_ADAPTER:-}" && -x "${GHOSTLIGHT_RECOVERY_ADAPTER:-}" ]] || {
    printf 'live recovery requires an executable GHOSTLIGHT_RECOVERY_ADAPTER\n' >&2
    exit 1
  }
  [[ ${#TARGET_TOKEN} -ge 16 ]] || {
    printf 'live recovery requires a target-specific token of at least 16 characters\n' >&2
    exit 1
  }
  [[ -z "$(git -C "$ROOT_DIR" status --porcelain --untracked-files=all)" ]] || {
    printf 'live recovery requires an exact clean source tree\n' >&2
    exit 1
  }
fi

mkdir -p "$OUTPUT_DIR"
chmod 700 "$OUTPUT_DIR"

set +e
node "$ROOT_DIR/tests/acceptance/recovery.mjs" "$RAW_RECEIPT" "$SOURCE_SHA" "$TARGET_ID" "$MODE"
harness_status=$?
node "$ROOT_DIR/tools/evaluate-recovery.mjs" "$RAW_RECEIPT" "$SOURCE_SHA" "$EVALUATION_RECEIPT"
evaluator_status=$?
set -e

if (( harness_status != 0 || evaluator_status != 0 )); then
  printf 'recovery matrix blocked; inspect %s and %s\n' "$RAW_RECEIPT" "$EVALUATION_RECEIPT" >&2
  exit 1
fi

printf 'recovery matrix accepted: %s\n' "$EVALUATION_RECEIPT"
