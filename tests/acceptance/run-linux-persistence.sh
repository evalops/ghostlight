#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_DIR="$ROOT_DIR/tests/acceptance"
FIXTURE_DIR="$TEST_DIR/fixtures"
OUTPUT_DIR="${GHOSTLIGHT_ACCEPTANCE_OUTPUT_DIR:-$ROOT_DIR/output/playwright/acceptance}"
PROJECT="${GHOSTLIGHT_ACCEPTANCE_PROJECT:-ghostlight_acceptance}"
CONTROL_PORT="${GHOSTLIGHT_ACCEPTANCE_CONTROL_PORT:-28080}"
VIEWER_PORT="${GHOSTLIGHT_ACCEPTANCE_VIEWER_PORT:-28081}"
WEBRTC_PORT="${GHOSTLIGHT_ACCEPTANCE_WEBRTC_PORT:-52080}"
CDP_PORT="${GHOSTLIGHT_ACCEPTANCE_CDP_PORT:-29280}"
MARKER="${GHOSTLIGHT_ACCEPTANCE_MARKER:-synthetic-$(date -u +%Y%m%dT%H%M%SZ)}"
SKIP_PROFILE_CHECK="${GHOSTLIGHT_ACCEPTANCE_SKIP_PROFILE_CHECK:-0}"
NEKO_IMAGE_REF="${NEKO_IMAGE:-ghcr.io/m1k1o/neko/chromium@sha256:a79093411aced75b3ed7110d50ec9082f9933afabd6592254f01c383678082e7}"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ghostlight-acceptance.XXXXXX")"
PROFILE_DIR="$WORK_DIR/chromium-profile"
ENV_FILE="$WORK_DIR/runtime.env"
OVERRIDE_FILE="$WORK_DIR/compose.override.yml"
TRANSCRIPT="$OUTPUT_DIR/transcript.txt"
SOURCE_SHA="${GHOSTLIGHT_ACCEPTANCE_SOURCE_SHA:-$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || printf unknown)}"
export COMPOSE_BAKE="${COMPOSE_BAKE:-false}"

finish() {
  local status=$?
  if [[ "${GHOSTLIGHT_ACCEPTANCE_KEEP_STACK:-0}" != 1 ]]; then
    docker compose --project-name "$PROJECT" --env-file "$ENV_FILE" -f "$ROOT_DIR/runtime/docker-compose.yml" -f "$OVERRIDE_FILE" down --remove-orphans >>"$TRANSCRIPT" 2>&1 || true
    rm -rf -- "$WORK_DIR" || true
  else
    printf 'acceptance work directory retained: %s\n' "$WORK_DIR" >&2
  fi
  trap - EXIT
  exit "$status"
}
trap finish EXIT

for command in docker node npm curl python3 shasum; do
  command -v "$command" >/dev/null || { printf 'missing required command: %s\n' "$command" >&2; exit 1; }
done
mkdir -p "$OUTPUT_DIR" "$PROFILE_DIR"
chmod 700 "$WORK_DIR" "$PROFILE_DIR"

cat >"$ENV_FILE" <<EOF
GHOSTLIGHT_BIND_ADDRESS=127.0.0.1
CONTROL_PORT=$CONTROL_PORT
VIEWER_PORT=$VIEWER_PORT
WEBRTC_MUX_PORT=$WEBRTC_PORT
CHROMIUM_PROFILE_DIR=$PROFILE_DIR
NEKO_USER_PASSWORD=acceptance-user-password
NEKO_ADMIN_PASSWORD=acceptance-admin-password
NEKO_WEBRTC_NAT1TO1=127.0.0.1
GHOSTLIGHT_VIEWER_URL=http://127.0.0.1:$VIEWER_PORT
GHOSTLIGHT_VIEWER_HEALTH_URL=http://viewer:8080
NEKO_IMAGE=$NEKO_IMAGE_REF
EOF
chmod 600 "$ENV_FILE"

cat >"$OVERRIDE_FILE" <<EOF
services:
  viewer:
    security_opt:
      - apparmor=unconfined
    ports:
      - target: 9223
        published: "$CDP_PORT"
        host_ip: 127.0.0.1
        protocol: tcp
    environment:
      GHOSTLIGHT_ACCEPTANCE_MARKER: "$MARKER"
    volumes:
      - "$FIXTURE_DIR/chromium.conf:/etc/neko/supervisord/chromium.conf:ro"
      - "$FIXTURE_DIR/cdp_proxy.py:/usr/local/bin/ghostlight-cdp-proxy.py:ro"
      - "$FIXTURE_DIR/cdp_proxy.conf:/etc/neko/supervisord/ghostlight-cdp-proxy.conf:ro"
      - "$FIXTURE_DIR/synthetic_server.py:/usr/local/bin/ghostlight-synthetic-server.py:ro"
      - "$FIXTURE_DIR/synthetic_server.conf:/etc/neko/supervisord/ghostlight-synthetic-server.conf:ro"
  control:
    security_opt:
      - apparmor=unconfined
EOF

: >"$TRANSCRIPT"
{
  printf 'captured_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'source_sha=%s\n' "$SOURCE_SHA"
  printf 'project=%s control_port=%s viewer_port=%s webrtc_port=%s cdp_port=%s\n' "$PROJECT" "$CONTROL_PORT" "$VIEWER_PORT" "$WEBRTC_PORT" "$CDP_PORT"
  printf 'marker=%s\n' "$MARKER"
  docker version --format 'docker_server={{.Server.Version}}'
  docker compose version
  node --version
  npm --version
} >>"$TRANSCRIPT" 2>&1

npm ci --prefix "$TEST_DIR" >>"$TRANSCRIPT" 2>&1
GHOSTLIGHT_ENV_FILE="$ENV_FILE" CHROMIUM_PROFILE_DIR="$PROFILE_DIR" GHOSTLIGHT_SKIP_PROFILE_RUNTIME_CHECK="$SKIP_PROFILE_CHECK" "$ROOT_DIR/runtime/bin/preflight.sh" >>"$TRANSCRIPT" 2>&1
docker compose --project-name "$PROJECT" --env-file "$ENV_FILE" -f "$ROOT_DIR/runtime/docker-compose.yml" -f "$OVERRIDE_FILE" up --detach --build >>"$TRANSCRIPT" 2>&1

for _attempt in {1..60}; do
  curl --fail --silent "http://127.0.0.1:$CDP_PORT/json/version" >/dev/null 2>&1 && break
  sleep 1
done
curl --fail --silent "http://127.0.0.1:$CDP_PORT/json/version" >>"$TRANSCRIPT"
printf '\n' >>"$TRANSCRIPT"

node "$TEST_DIR/persistence.mjs" "http://127.0.0.1:$CDP_PORT" before "$OUTPUT_DIR" "$MARKER" >>"$TRANSCRIPT" 2>&1
BEFORE_VIEWER="$(docker compose --project-name "$PROJECT" --env-file "$ENV_FILE" -f "$ROOT_DIR/runtime/docker-compose.yml" -f "$OVERRIDE_FILE" ps -q viewer)"
BEFORE_CONTROL="$(docker compose --project-name "$PROJECT" --env-file "$ENV_FILE" -f "$ROOT_DIR/runtime/docker-compose.yml" -f "$OVERRIDE_FILE" ps -q control)"
docker compose --project-name "$PROJECT" --env-file "$ENV_FILE" -f "$ROOT_DIR/runtime/docker-compose.yml" -f "$OVERRIDE_FILE" down >>"$TRANSCRIPT" 2>&1
docker compose --project-name "$PROJECT" --env-file "$ENV_FILE" -f "$ROOT_DIR/runtime/docker-compose.yml" -f "$OVERRIDE_FILE" up --detach --build >>"$TRANSCRIPT" 2>&1

for _attempt in {1..60}; do
  curl --fail --silent "http://127.0.0.1:$CDP_PORT/json/version" >/dev/null 2>&1 && break
  sleep 1
done
node "$TEST_DIR/persistence.mjs" "http://127.0.0.1:$CDP_PORT" after "$OUTPUT_DIR" "$MARKER" >>"$TRANSCRIPT" 2>&1
AFTER_VIEWER="$(docker compose --project-name "$PROJECT" --env-file "$ENV_FILE" -f "$ROOT_DIR/runtime/docker-compose.yml" -f "$OVERRIDE_FILE" ps -q viewer)"
AFTER_CONTROL="$(docker compose --project-name "$PROJECT" --env-file "$ENV_FILE" -f "$ROOT_DIR/runtime/docker-compose.yml" -f "$OVERRIDE_FILE" ps -q control)"
[[ "$BEFORE_VIEWER" != "$AFTER_VIEWER" && "$BEFORE_CONTROL" != "$AFTER_CONTROL" ]]

{
  printf 'before_viewer=%s\nafter_viewer=%s\n' "$BEFORE_VIEWER" "$AFTER_VIEWER"
  printf 'before_control=%s\nafter_control=%s\n' "$BEFORE_CONTROL" "$AFTER_CONTROL"
  docker compose --project-name "$PROJECT" --env-file "$ENV_FILE" -f "$ROOT_DIR/runtime/docker-compose.yml" -f "$OVERRIDE_FILE" ps
  docker compose --project-name "$PROJECT" --env-file "$ENV_FILE" -f "$ROOT_DIR/runtime/docker-compose.yml" -f "$OVERRIDE_FILE" exec -T viewer sh -lc 'tail -20 /home/neko/.config/chromium/acceptance-requests.jsonl'
  python3 "$TEST_DIR/audit-screenshots.py" "$OUTPUT_DIR"/*.png
  shasum -a 256 "$OUTPUT_DIR"/*.png "$OUTPUT_DIR"/*-evidence.json
} >>"$TRANSCRIPT" 2>&1

printf 'acceptance passed; evidence: %s\n' "$OUTPUT_DIR"
