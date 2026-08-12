#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$ROOT_DIR/tests/acceptance"
OUTPUT_DIR="${GHOSTLIGHT_PERFORMANCE_OUTPUT_DIR:-$ROOT_DIR/output/playwright/performance}"
VIEWER_URL="${GHOSTLIGHT_PERFORMANCE_VIEWER_URL:-}"
VIEWER_CONTAINER="${GHOSTLIGHT_PERFORMANCE_VIEWER_CONTAINER:-}"
NEKO_PASSWORD="${GHOSTLIGHT_PERFORMANCE_NEKO_PASSWORD:-}"
DISPLAY_NAME="${GHOSTLIGHT_PERFORMANCE_DISPLAY_NAME:-Ghostlight Performance}"
LOCKFILE="$TEST_DIR/package-lock.json"

[[ -n "$VIEWER_URL" ]] || { printf 'set GHOSTLIGHT_PERFORMANCE_VIEWER_URL\n' >&2; exit 1; }
[[ -n "$VIEWER_CONTAINER" ]] || { printf 'set GHOSTLIGHT_PERFORMANCE_VIEWER_CONTAINER\n' >&2; exit 1; }
[[ -n "$NEKO_PASSWORD" ]] || { printf 'set GHOSTLIGHT_PERFORMANCE_NEKO_PASSWORD\n' >&2; exit 1; }
for command in docker git node npm shasum; do
  command -v "$command" >/dev/null || { printf 'missing command: %s\n' "$command" >&2; exit 1; }
done
[[ -f "$LOCKFILE" ]] || { printf 'missing acceptance lockfile: %s\n' "$LOCKFILE" >&2; exit 1; }

SOURCE_SHA="$(git -C "$ROOT_DIR" rev-parse --verify HEAD)"
if [[ -n "$(git -C "$ROOT_DIR" status --porcelain --untracked-files=all)" ]]; then
  printf 'refusing to collect an exact-source receipt from a dirty worktree\n' >&2
  exit 1
fi
VIEWER_CONTAINER_ID="$(docker inspect --format '{{.Id}}' "$VIEWER_CONTAINER")"
VIEWER_IMAGE_ID="$(docker inspect --format '{{.Image}}' "$VIEWER_CONTAINER")"
VIEWER_IMAGE_REFERENCE="$(docker inspect --format '{{.Config.Image}}' "$VIEWER_CONTAINER")"
[[ "$VIEWER_IMAGE_REFERENCE" == *@sha256:* ]] || {
  printf 'viewer image reference is not digest-pinned: %s\n' "$VIEWER_IMAGE_REFERENCE" >&2
  exit 1
}
ACCEPTANCE_LOCKFILE_SHA256="$(shasum -a 256 "$LOCKFILE" | awk '{print $1}')"

mkdir -p "$OUTPUT_DIR"
npm ci --prefix "$TEST_DIR"
docker exec "$VIEWER_CONTAINER" sh -c \
  'if [ -f /var/log/neko/neko.log ]; then tail -100 /var/log/neko/neko.log; else printf "Neko pipeline log is not present in this image\\n"; fi' \
  >"$OUTPUT_DIR/neko-pipeline.log"
GHOSTLIGHT_PERFORMANCE_NEKO_PASSWORD="$NEKO_PASSWORD" \
  node "$TEST_DIR/performance.mjs" "$VIEWER_URL" "$DISPLAY_NAME" "$OUTPUT_DIR/webrtc.json" &
PERF_PID=$!
trap 'kill "$PERF_PID" 2>/dev/null' EXIT
: >"$OUTPUT_DIR/container-stats.jsonl"
while kill -0 "$PERF_PID" 2>/dev/null; do
  docker stats --no-stream --format '{{json .}}' "$VIEWER_CONTAINER" >>"$OUTPUT_DIR/container-stats.jsonl"
  sleep 1
done
wait "$PERF_PID"
FINAL_SOURCE_SHA="$(git -C "$ROOT_DIR" rev-parse --verify HEAD)"
FINAL_VIEWER_CONTAINER_ID="$(docker inspect --format '{{.Id}}' "$VIEWER_CONTAINER")"
FINAL_VIEWER_IMAGE_ID="$(docker inspect --format '{{.Image}}' "$VIEWER_CONTAINER")"
FINAL_ACCEPTANCE_LOCKFILE_SHA256="$(shasum -a 256 "$LOCKFILE" | awk '{print $1}')"
[[ "$FINAL_SOURCE_SHA" == "$SOURCE_SHA" ]] || { printf 'source HEAD changed during collection\n' >&2; exit 1; }
[[ -z "$(git -C "$ROOT_DIR" status --porcelain --untracked-files=all)" ]] || {
  printf 'source tree changed during collection\n' >&2
  exit 1
}
[[ "$FINAL_VIEWER_CONTAINER_ID" == "$VIEWER_CONTAINER_ID" && "$FINAL_VIEWER_IMAGE_ID" == "$VIEWER_IMAGE_ID" ]] || {
  printf 'viewer container or image changed during collection\n' >&2
  exit 1
}
[[ "$FINAL_ACCEPTANCE_LOCKFILE_SHA256" == "$ACCEPTANCE_LOCKFILE_SHA256" ]] || {
  printf 'acceptance lockfile changed during collection\n' >&2
  exit 1
}
VIEWER_ENDPOINT_SHA256="$(printf '%s' "$VIEWER_URL" | shasum -a 256 | awk '{print $1}')"
{
  printf 'captured_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'source_sha=%s\nsource_tree=clean\n' "$SOURCE_SHA"
  printf 'viewer_endpoint_sha256=%s\nviewer_container=%s\n' "$VIEWER_ENDPOINT_SHA256" "$VIEWER_CONTAINER"
  printf 'viewer_container_id=%s\nviewer_image_reference=%s\nviewer_image_id=%s\n' \
    "$VIEWER_CONTAINER_ID" "$VIEWER_IMAGE_REFERENCE" "$VIEWER_IMAGE_ID"
  printf 'acceptance_lockfile=tests/acceptance/package-lock.json\n'
  printf 'acceptance_lockfile_sha256=%s\n' "$ACCEPTANCE_LOCKFILE_SHA256"
  docker version --format 'docker_server={{.Server.Version}}'
  node --version
  npm --version
  shasum -a 256 "$OUTPUT_DIR"/*.json "$OUTPUT_DIR"/*.jsonl "$OUTPUT_DIR"/*.log
} >"$OUTPUT_DIR/transcript.txt"
printf 'performance evidence: %s\n' "$OUTPUT_DIR"
