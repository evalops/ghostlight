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
require_command grep
require_command sed

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
CONTROL_READY_PATH="${CONTROL_READY_PATH:-$(env_value CONTROL_READY_PATH)}"
CONTROL_READY_PATH="${CONTROL_READY_PATH:-/readyz}"
VIEWER_HEALTH_PATH="${VIEWER_HEALTH_PATH:-$(env_value VIEWER_HEALTH_PATH)}"
VIEWER_HEALTH_PATH="${VIEWER_HEALTH_PATH:-/health}"
VIEWER_DISCOVERY_PATH="${VIEWER_DISCOVERY_PATH:-$(env_value VIEWER_DISCOVERY_PATH)}"
VIEWER_DISCOVERY_PATH="${VIEWER_DISCOVERY_PATH:-/v1/viewer}"

CONTROL_URL="${GHOSTLIGHT_CONTROL_URL:-http://127.0.0.1:$CONTROL_PORT}"
DIRECT_VIEWER_URL="${GHOSTLIGHT_SMOKE_VIEWER_URL:-http://127.0.0.1:$VIEWER_PORT}"

CONTROL_HEALTH_URL="${CONTROL_URL%/}${CONTROL_HEALTH_PATH}"
CONTROL_READY_URL="${CONTROL_URL%/}${CONTROL_READY_PATH}"
VIEWER_HEALTH_URL="${DIRECT_VIEWER_URL%/}${VIEWER_HEALTH_PATH}"
VIEWER_DISCOVERY_URL="${CONTROL_URL%/}${VIEWER_DISCOVERY_PATH}"

health_response="$(request_with_retry "$CONTROL_HEALTH_URL")" \
  || die "control liveness failed at $CONTROL_HEALTH_URL; inspect 'docker compose --env-file $ENV_FILE -f $COMPOSE_FILE logs control'"
printf '%s' "$health_response" | grep -Eq '"status"[[:space:]]*:[[:space:]]*"ok"' \
  || die "control liveness at $CONTROL_HEALTH_URL did not return JSON status=ok"

request_with_retry "$VIEWER_HEALTH_URL" \
  || die "viewer health failed at $VIEWER_HEALTH_URL; check viewer port $VIEWER_PORT and the Neko container logs"

ready_response="$(request_with_retry "$CONTROL_READY_URL")" \
  || die "control readiness failed at $CONTROL_READY_URL; viewer health may be unavailable"
printf '%s' "$ready_response" | grep -Eq '"viewer"[[:space:]]*:[[:space:]]*"ready"' \
  || die "control readiness at $CONTROL_READY_URL did not report viewer=ready"

discovery_response="$(request_once "$VIEWER_DISCOVERY_URL")" \
  || die "viewer discovery failed at $VIEWER_DISCOVERY_URL; inspect control logs"
printf '%s' "$discovery_response" | grep -Eq '"viewer_url"[[:space:]]*:[[:space:]]*"[^" ]+"' \
  || die "viewer discovery response from $VIEWER_DISCOVERY_URL has no viewer_url field"

discovered_viewer_url="$(printf '%s' "$discovery_response" | sed -n 's/.*"viewer_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
[[ -n "$discovered_viewer_url" ]] || die "could not read viewer_url from the discovery response"
request_with_retry "${discovered_viewer_url%/}${VIEWER_HEALTH_PATH}" \
  || die "discovered viewer health failed at $discovered_viewer_url; check GHOSTLIGHT_VIEWER_URL and NEKO_WEBRTC_NAT1TO1"

printf 'smoke passed: control liveness, viewer /health, control readiness, and stateless viewer discovery (%s)\n' "$discovered_viewer_url"
