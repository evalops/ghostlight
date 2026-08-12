#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
node "$ROOT_DIR/tools/measure-streaming-performance.mjs" --self-test

error_output="$(mktemp)"
trap 'rm -f -- "$error_output"' EXIT
if GHOSTLIGHT_PERFORMANCE_SOURCE_SHA=not-the-checked-out-head "$ROOT_DIR/tools/measure-streaming-performance.sh" --json >"$error_output" 2>&1; then
  echo "invalid source override was accepted" >&2
  exit 1
fi
grep -F "GHOSTLIGHT_PERFORMANCE_SOURCE_SHA must match git rev-parse HEAD" "$error_output" >/dev/null
