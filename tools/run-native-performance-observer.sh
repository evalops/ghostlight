#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
VIEWER_URL="${GHOSTLIGHT_NATIVE_PERFORMANCE_VIEWER_URL:-}"
PASSWORD="${GHOSTLIGHT_NATIVE_PERFORMANCE_NEKO_PASSWORD:-}"
EXPECTED_CODEC="${GHOSTLIGHT_NATIVE_PERFORMANCE_EXPECTED_CODEC:-}"
SOURCE_SHA="${GHOSTLIGHT_NATIVE_PERFORMANCE_SOURCE_SHA:-}"
OUTPUT_DIR="${GHOSTLIGHT_NATIVE_PERFORMANCE_OUTPUT_DIR:-$ROOT_DIR/output/native-performance}"
APP_PATH="${GHOSTLIGHT_APP_PATH:-$ROOT_DIR/macos/.build/Ghostlight.app}"
STOP_FILE="${GHOSTLIGHT_NATIVE_PERFORMANCE_STOP_FILE:-}"
PHASE_DIR="${GHOSTLIGHT_NATIVE_PERFORMANCE_PHASE_DIR:-}"
MAX_WAIT_SECONDS="${GHOSTLIGHT_NATIVE_PERFORMANCE_MAX_WAIT_SECONDS:-360}"

[[ "$(uname -s)" == Darwin ]] || { printf 'macOS is required\n' >&2; exit 1; }
[[ -n "$VIEWER_URL" && -n "$PASSWORD" && -n "$EXPECTED_CODEC" && -n "$SOURCE_SHA" ]] || { printf 'native performance environment is incomplete\n' >&2; exit 1; }
[[ -n "$STOP_FILE" && -f "$STOP_FILE" && -n "$PHASE_DIR" && -d "$PHASE_DIR" ]] || { printf 'native performance phase coordination is incomplete\n' >&2; exit 1; }
[[ "$EXPECTED_CODEC" == vp8 || "$EXPECTED_CODEC" == h264 ]] || { printf 'expected codec must be vp8 or h264\n' >&2; exit 1; }
[[ "$MAX_WAIT_SECONDS" =~ ^[0-9]+$ && "$MAX_WAIT_SECONDS" -ge 60 ]] || { printf 'native performance wait must be at least 60 seconds\n' >&2; exit 1; }
[[ "$SOURCE_SHA" == "$(git -C "$ROOT_DIR" rev-parse HEAD)" ]] || { printf 'native source SHA must match HEAD\n' >&2; exit 1; }
[[ -x "$APP_PATH/Contents/MacOS/GhostlightApp" ]] || { printf 'package Ghostlight.app before native measurement\n' >&2; exit 1; }

mkdir -p "$OUTPUT_DIR"
chmod 700 "$OUTPUT_DIR"
RAW_RECEIPT="$OUTPUT_DIR/wkwebview-raw.json"
CPU_SAMPLES="$OUTPUT_DIR/macos-process-stats.tsv"
RECEIPT="$OUTPUT_DIR/native-receipt.json"
BASELINE_PIDS="$OUTPUT_DIR/webkit-baseline-pids.txt"
CONTROL_LOG="$OUTPUT_DIR/control.log"
APP_LOG="$OUTPUT_DIR/app.log"
: >"$CPU_SAMPLES"
: >"$CONTROL_LOG"
: >"$APP_LOG"
chmod 600 "$CPU_SAMPLES" "$CONTROL_LOG" "$APP_LOG"

CONTROL_PORT="$(python3 - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
)"
ps -axo pid=,command= | awk '/com\.apple\.WebKit\.(WebContent|GPU|Networking)/ {print $1}' >"$BASELINE_PIDS"
chmod 600 "$BASELINE_PIDS"

CONTROL_PID=""
APP_PID=""
SAMPLER_PID=""
cleanup_native_observer() {
  osascript -e 'tell application id "org.evalops.Ghostlight" to quit' >/dev/null 2>&1 || true
  [[ -z "$SAMPLER_PID" ]] || kill "$SAMPLER_PID" >/dev/null 2>&1 || true
  [[ -z "$APP_PID" ]] || kill "$APP_PID" >/dev/null 2>&1 || true
  [[ -z "$CONTROL_PID" ]] || kill "$CONTROL_PID" >/dev/null 2>&1 || true
}
trap cleanup_native_observer EXIT

python3 "$ROOT_DIR/tools/native-performance-control.py" --port "$CONTROL_PORT" --viewer-url "$VIEWER_URL" >"$CONTROL_LOG" 2>&1 &
CONTROL_PID=$!
for _ in {1..50}; do
  curl --fail --silent "http://127.0.0.1:$CONTROL_PORT/healthz" >/dev/null 2>&1 && break
  sleep 0.1
done
curl --fail --silent "http://127.0.0.1:$CONTROL_PORT/healthz" >/dev/null

osascript -e 'tell application id "org.evalops.Ghostlight" to quit' >/dev/null 2>&1 || true
sleep 1
GHOSTLIGHT_CONTROL_URL="http://127.0.0.1:$CONTROL_PORT" \
GHOSTLIGHT_NATIVE_PERFORMANCE_OUTPUT="$RAW_RECEIPT" \
GHOSTLIGHT_NATIVE_PERFORMANCE_NEKO_PASSWORD="$PASSWORD" \
GHOSTLIGHT_NATIVE_PERFORMANCE_SOURCE_SHA="$SOURCE_SHA" \
GHOSTLIGHT_NATIVE_PERFORMANCE_EXPECTED_CODEC="$EXPECTED_CODEC" \
"$APP_PATH/Contents/MacOS/GhostlightApp" >"$APP_LOG" 2>&1 &
APP_PID=$!

(
  while kill -0 "$APP_PID" >/dev/null 2>&1; do
    captured_at="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
    ps -axo pid=,ppid=,%cpu=,rss=,command= | while read -r pid ppid cpu rss command; do
      lineage=""
      if [[ "$pid" == "$APP_PID" ]]; then
        lineage="app"
      elif [[ "$command" == *com.apple.WebKit.WebContent* || "$command" == *com.apple.WebKit.GPU* || "$command" == *com.apple.WebKit.Networking* ]]; then
        grep -qx "$pid" "$BASELINE_PIDS" && continue
        lineage="new-webkit-process"
      else
        continue
      fi
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$captured_at" "$pid" "$ppid" "$cpu" "$rss" "$lineage" "$command"
    done >>"$CPU_SAMPLES"
    sleep 1
  done
) &
SAMPLER_PID=$!

ready=0
for _ in {1..60}; do
  if [[ -s "$RAW_RECEIPT" ]] && python3 - "$RAW_RECEIPT" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
samples = [sample for sample in data.get("samples", []) if sample.get("active_media") == 1]
raise SystemExit(0 if len(samples) >= 10 and samples[-1].get("frames_decoded", 0) > samples[0].get("frames_decoded", 0) else 1)
PY
  then
    ready=1
    break
  fi
  sleep 1
done
[[ "$ready" == 1 ]] || { printf 'WKWebView did not produce ten active media samples\n' >&2; exit 1; }

deadline=$((SECONDS + MAX_WAIT_SECONDS))
while [[ -f "$STOP_FILE" && "$SECONDS" -lt "$deadline" ]]; do
  kill -0 "$APP_PID" >/dev/null 2>&1 || { printf 'Ghostlight.app exited before all benchmark phases completed\n' >&2; exit 1; }
  sleep 1
done
[[ ! -f "$STOP_FILE" ]] || { printf 'native observer phase coordination timed out\n' >&2; exit 1; }

osascript -e 'tell application id "org.evalops.Ghostlight" to quit' >/dev/null 2>&1 || true
wait "$APP_PID" >/dev/null 2>&1 || true
APP_PID=""
wait "$SAMPLER_PID" >/dev/null 2>&1 || true
SAMPLER_PID=""
node "$ROOT_DIR/tools/evaluate-native-performance.mjs" "$RAW_RECEIPT" "$CPU_SAMPLES" "$EXPECTED_CODEC" "$SOURCE_SHA" "$RECEIPT" "$PHASE_DIR"
