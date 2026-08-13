#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
captured_at="2026-08-13T00:00:00.000Z"
output="$(printf '%s\n' \
  '100 1 8.0 102400 /tmp/Ghostlight.app/Contents/MacOS/GhostlightApp' \
  '200 100 4.0 204800 /System/com.apple.WebKit.WebContent' \
  '201 200 2.0 102400 /System/com.apple.WebKit.GPU' \
  '300 1 7.0 307200 /System/com.apple.WebKit.WebContent' \
  | awk -v captured_at="$captured_at" -v app_pid=100 -f "$ROOT_DIR/tools/native-performance-processes.awk")"

[[ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" == 3 ]]
printf '%s\n' "$output" | grep -Fq $'\t100\t1\t8.0\t102400\tapp\t100\t'
printf '%s\n' "$output" | grep -Fq $'\t200\t100\t4.0\t204800\tapp-owned-webkit-process\t100\t'
printf '%s\n' "$output" | grep -Fq $'\t201\t200\t2.0\t102400\tapp-owned-webkit-process\t100\t'
if printf '%s\n' "$output" | grep -Fq $'\t300\t'; then
  printf 'unowned WebKit process was attributed to GhostlightApp\n' >&2
  exit 1
fi
