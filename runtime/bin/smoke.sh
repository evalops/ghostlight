#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
COMPOSE_FILE="$RUNTIME_DIR/docker-compose.yml"
ENV_FILE="${GHOSTLIGHT_ENV_FILE:-$RUNTIME_DIR/.env}"
ATTEMPTS="${SMOKE_ATTEMPTS:-30}"

die() {
  printf 'smoke: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "missing '$1'; install Docker Compose and curl before running the smoke check"
}

env_value() {
  local key="$1"
  local value

  value="$(awk -F= -v wanted="$key" '
    $0 !~ /^[[:space:]]*#/ && $0 ~ "^[[:space:]]*" wanted "[[:space:]]*=" {
      sub(/^[^=]*=/, "", $0)
      print $0
      exit
    }
  ' "$ENV_FILE")"
  value="${value#\"}"
  value="${value%\"}"
  value="${value#\'}"
  value="${value%\'}"
  printf '%s' "$value"
}

request_once() {
  local url="$1"
  shift

  curl --fail --silent --show-error --connect-timeout 2 --max-time 10 "$@" "$url"
}

request_with_retry() {
  local url="$1"
  shift
  local attempt response

  for ((attempt = 1; attempt <= ATTEMPTS; attempt++)); do
    if response="$(request_once "$url" "$@")"; then
      printf '%s' "$response"
      return 0
    fi
    sleep 1
  done

  return 1
}

require_command docker
require_command curl
require_command awk

[[ -f "$ENV_FILE" ]] || die "runtime/.env is missing; run 'cp runtime/.env.example runtime/.env' and replace the placeholders"
if "$SCRIPT_DIR/find-placeholders.sh" "$ENV_FILE"; then
  die "runtime/.env still contains install-time placeholders; generate passwords and set the reachable viewer address"
fi

docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" config --quiet \
  || die "Compose config is invalid; run 'docker compose --env-file $ENV_FILE -f $COMPOSE_FILE config' for details"

CONTROL_PORT="${CONTROL_PORT:-$(env_value CONTROL_PORT)}"
CONTROL_PORT="${CONTROL_PORT:-8080}"
VIEWER_PORT="${VIEWER_PORT:-$(env_value VIEWER_PORT)}"
VIEWER_PORT="${VIEWER_PORT:-8081}"
CONTROL_HEALTH_PATH="${CONTROL_HEALTH_PATH:-$(env_value CONTROL_HEALTH_PATH)}"
CONTROL_HEALTH_PATH="${CONTROL_HEALTH_PATH:-/healthz}"
SESSION_CREATE_PATH="${SESSION_CREATE_PATH:-$(env_value SESSION_CREATE_PATH)}"
SESSION_CREATE_PATH="${SESSION_CREATE_PATH:-/v1/sessions}"
CONTROL_URL="${GHOSTLIGHT_CONTROL_URL:-http://127.0.0.1:$CONTROL_PORT}"
DIRECT_VIEWER_URL="${GHOSTLIGHT_SMOKE_VIEWER_URL:-http://127.0.0.1:$VIEWER_PORT}"

CONTROL_HEALTH_URL="${CONTROL_URL%/}${CONTROL_HEALTH_PATH}"
SESSION_CREATE_URL="${CONTROL_URL%/}${SESSION_CREATE_PATH}"

health_response="$(request_with_retry "$CONTROL_HEALTH_URL")" \
  || die "control health failed at $CONTROL_HEALTH_URL; inspect 'docker compose --env-file $ENV_FILE -f $COMPOSE_FILE logs control'"
printf '%s' "$health_response" | grep -Eq '"status"[[:space:]]*:[[:space:]]*"ok"' \
  || die "control health at $CONTROL_HEALTH_URL did not return JSON status=ok"

request_with_retry "${DIRECT_VIEWER_URL%/}/" \
  || die "viewer is unreachable at $DIRECT_VIEWER_URL; check viewer port $VIEWER_PORT and the Neko container logs"

session_response="$(request_once "$SESSION_CREATE_URL" -X POST -H 'Content-Type: application/json' --data '{}')" \
  || die "session creation failed at $SESSION_CREATE_URL; inspect control logs and confirm POST /v1/sessions accepts JSON"
printf '%s' "$session_response" | grep -Eq '"id"[[:space:]]*:[[:space:]]*"[^" ]+"' \
  || die "session response from $SESSION_CREATE_URL has no id field"
printf '%s' "$session_response" | grep -Eq '"viewer_url"[[:space:]]*:[[:space:]]*"[^" ]+"' \
  || die "session response from $SESSION_CREATE_URL has no viewer_url field"
printf '%s' "$session_response" | grep -Eq '"created_at"[[:space:]]*:' \
  || die "session response from $SESSION_CREATE_URL has no created_at field"

session_viewer_url="$(printf '%s' "$session_response" | sed -n 's/.*"viewer_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
[[ -n "$session_viewer_url" ]] || die "could not read viewer_url from the session response"
request_with_retry "${session_viewer_url%/}/" \
  || die "viewer is unreachable at $session_viewer_url; check viewer port 8081 and WebRTC host configuration"

printf 'smoke passed: control health, session creation, and viewer reachability (%s)\n' "$session_viewer_url"
