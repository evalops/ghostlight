#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
COMPOSE_FILE="$RUNTIME_DIR/docker-compose.yml"
EXAMPLE_ENV="$RUNTIME_DIR/.env.example"
ENV_FILE="${GHOSTLIGHT_ENV_FILE:-$RUNTIME_DIR/.env}"
CONTROL_DIR="$RUNTIME_DIR/../control"
PROFILE_DIR="$RUNTIME_DIR/data/chromium"
CONTROL_DATA_DIR="$RUNTIME_DIR/data/control"

die() {
  printf 'preflight: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "missing '$1'; install Docker Compose and curl before running the runtime"
}

require_command docker
require_command curl

[[ -f "$COMPOSE_FILE" ]] || die "missing $COMPOSE_FILE"
[[ -f "$EXAMPLE_ENV" ]] || die "missing $EXAMPLE_ENV"

COMPOSE_ENV_FILE="$ENV_FILE"
if [[ ! -f "$ENV_FILE" ]]; then
  COMPOSE_ENV_FILE="$EXAMPLE_ENV"
  printf 'preflight: runtime/.env is missing; using .env.example for the Compose syntax check\n' >&2
fi

docker compose --env-file "$COMPOSE_ENV_FILE" -f "$COMPOSE_FILE" config --quiet \
  || die "Compose config is invalid; run 'docker compose --env-file $COMPOSE_ENV_FILE -f $COMPOSE_FILE config' for details"

if [[ ! -f "$ENV_FILE" ]]; then
  die "create runtime/.env with 'cp runtime/.env.example runtime/.env', then replace every __GENERATE_AT_INSTALL__ value"
fi

if grep --line-number --fixed-strings '__GENERATE_AT_INSTALL__' "$ENV_FILE"; then
  die "runtime/.env still contains install-time placeholders; generate passwords and set the reachable viewer address"
fi

[[ -d "$CONTROL_DIR" ]] || die "control source is missing at $CONTROL_DIR; check out the control API beside runtime"
[[ -f "$CONTROL_DIR/Dockerfile" ]] || die "control/Dockerfile is missing; the control service must be buildable from ../control"

mkdir -p "$PROFILE_DIR" "$CONTROL_DATA_DIR"
[[ -w "$PROFILE_DIR" ]] || die "Chromium profile directory is not writable: $PROFILE_DIR; grant the Docker user access"
[[ -w "$CONTROL_DATA_DIR" ]] || die "control data directory is not writable: $CONTROL_DATA_DIR; grant the Docker user access"

printf 'preflight passed: Compose config, control source, data directories, and environment checks\n'
