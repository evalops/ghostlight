#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ "${1:-}" != "--json" ]]; then
  printf 'usage: %s --json\n' "$0" >&2
  exit 2
fi

command -v node >/dev/null 2>&1 || { printf 'missing command: node\n' >&2; exit 1; }
command -v ssh >/dev/null 2>&1 || { printf 'missing command: ssh\n' >&2; exit 1; }
command -v scp >/dev/null 2>&1 || { printf 'missing command: scp\n' >&2; exit 1; }

exec node "$ROOT_DIR/tools/measure-streaming-performance.mjs" --json
