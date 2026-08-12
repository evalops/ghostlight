#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$ROOT_DIR/tests/acceptance"
OUTPUT_DIR="${GHOSTLIGHT_PERFORMANCE_OUTPUT_DIR:-$ROOT_DIR/output/playwright/performance}"
VIEWER_URL="${GHOSTLIGHT_PERFORMANCE_VIEWER_URL:-}"
VIEWER_CONTAINER="${GHOSTLIGHT_PERFORMANCE_VIEWER_CONTAINER:-}"
NEKO_PASSWORD="${GHOSTLIGHT_PERFORMANCE_NEKO_PASSWORD:-}"
DISPLAY_NAME="${GHOSTLIGHT_PERFORMANCE_DISPLAY_NAME:-Ghostlight Performance}"
SOURCE_SHA="${GHOSTLIGHT_PERFORMANCE_SOURCE_SHA:-$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || printf unknown)}"

[[ -n "$VIEWER_URL" ]] || { printf 'set GHOSTLIGHT_PERFORMANCE_VIEWER_URL\n' >&2; exit 1; }
[[ -n "$VIEWER_CONTAINER" ]] || { printf 'set GHOSTLIGHT_PERFORMANCE_VIEWER_CONTAINER\n' >&2; exit 1; }
[[ -n "$NEKO_PASSWORD" ]] || { printf 'set GHOSTLIGHT_PERFORMANCE_NEKO_PASSWORD\n' >&2; exit 1; }
for command in docker node npm shasum; do
  command -v "$command" >/dev/null || { printf 'missing command: %s\n' "$command" >&2; exit 1; }
done

mkdir -p "$OUTPUT_DIR"
npm ci --prefix "$TEST_DIR"
docker exec "$VIEWER_CONTAINER" sh -c \
  'if [ -f /var/log/neko/neko.log ]; then tail -100 /var/log/neko/neko.log; else printf "Neko pipeline log is not present in this image\\n"; fi' \
  >"$OUTPUT_DIR/neko-pipeline.log"
node "$TEST_DIR/performance.mjs" "$VIEWER_URL" "$DISPLAY_NAME" "$NEKO_PASSWORD" "$OUTPUT_DIR/webrtc.json" &
PERF_PID=$!
: >"$OUTPUT_DIR/container-stats.jsonl"
while kill -0 "$PERF_PID" 2>/dev/null; do
  docker stats --no-stream --format '{{json .}}' "$VIEWER_CONTAINER" >>"$OUTPUT_DIR/container-stats.jsonl"
  sleep 1
done
wait "$PERF_PID"
VIEWER_ENDPOINT_SHA256="$(printf '%s' "$VIEWER_URL" | shasum -a 256 | awk '{print $1}')"
{
  printf 'captured_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'source_sha=%s\n' "$SOURCE_SHA"
  printf 'viewer_endpoint_sha256=%s\nviewer_container=%s\n' "$VIEWER_ENDPOINT_SHA256" "$VIEWER_CONTAINER"
  docker version --format 'docker_server={{.Server.Version}}'
  node --version
  shasum -a 256 "$OUTPUT_DIR"/*.json "$OUTPUT_DIR"/*.jsonl "$OUTPUT_DIR"/*.log
} >"$OUTPUT_DIR/transcript.txt"
printf 'performance evidence: %s\n' "$OUTPUT_DIR"
