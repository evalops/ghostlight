#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
COMPOSE_FILE="$RUNTIME_DIR/docker-compose.yml"
EXAMPLE_ENV="$RUNTIME_DIR/.env.example"
ENV_FILE="${GHOSTLIGHT_ENV_FILE:-$RUNTIME_DIR/.env}"
CONTROL_DIR="$RUNTIME_DIR/../control"
PROFILE_DIR="${CHROMIUM_PROFILE_DIR:-$RUNTIME_DIR/data/chromium}"

die() {
  printf 'preflight: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "missing '$1'; install Docker Compose and curl before running the runtime"
}

stat_mode() {
  if stat -c '%a' "$1" >/dev/null 2>&1; then
    stat -c '%a' "$1"
  else
    stat -f '%Lp' "$1"
  fi
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

is_private_bind_address() {
  local address="$1"
  local first second third fourth

  case "$address" in
    ::1|[fF][cCdD][0-9a-fA-F][0-9a-fA-F]:*|[fF][eE][89aAbB][0-9a-fA-F]:*)
      return 0
      ;;
  esac

  IFS=. read -r first second third fourth <<<"$address"
  for octet in "$first" "$second" "$third" "$fourth"; do
    [[ "$octet" =~ ^[0-9]+$ ]] || return 1
    (( 10#$octet <= 255 )) || return 1
  done

  (( first == 10 || first == 127 )) && return 0
  (( first == 172 && second >= 16 && second <= 31 )) && return 0
  (( first == 192 && second == 168 )) && return 0
  (( first == 169 && second == 254 )) && return 0
  return 1
}

require_command docker
require_command curl
require_command awk

[[ -f "$COMPOSE_FILE" ]] || die "missing $COMPOSE_FILE"
[[ -f "$EXAMPLE_ENV" ]] || die "missing $EXAMPLE_ENV"
[[ -f "$ENV_FILE" ]] || die "create runtime/.env with 'cp runtime/.env.example runtime/.env', then replace every __GENERATE_AT_INSTALL__ value"
[[ ! -L "$ENV_FILE" ]] || die "runtime/.env must not be a symlink"

env_mode="$(stat_mode "$ENV_FILE")"
[[ "$env_mode" == 600 ]] || die "runtime/.env must have mode 600; use chmod 600 runtime/.env"

if "$SCRIPT_DIR/find-placeholders.sh" "$ENV_FILE"; then
  die "runtime/.env still contains install-time placeholders; generate passwords and set the reachable viewer address"
fi

bind_address="$(env_value GHOSTLIGHT_BIND_ADDRESS)"
[[ -n "$bind_address" ]] || die "GHOSTLIGHT_BIND_ADDRESS must be explicit in runtime/.env"
is_private_bind_address "$bind_address" \
  || die "GHOSTLIGHT_BIND_ADDRESS must be a literal loopback, link-local, or private IP address"

viewer_url="$(env_value GHOSTLIGHT_VIEWER_URL)"
nat_address="$(env_value NEKO_WEBRTC_NAT1TO1)"
[[ -n "$viewer_url" && -n "$nat_address" ]] || die "GHOSTLIGHT_VIEWER_URL and NEKO_WEBRTC_NAT1TO1 must both be configured"

viewer_host="$(printf '%s' "$viewer_url" | sed -E 's#^[[:alpha:]][[:alnum:]+.-]*://([^/@]+@)?(\[[^]]+\]|[^:/]+)(:[0-9]+)?(/.*)?$#\2#')"
[[ "$viewer_host" != "$viewer_url" ]] || die "GHOSTLIGHT_VIEWER_URL must be an absolute URL with a host"
viewer_host="${viewer_host#[}"
viewer_host="${viewer_host%]}"
nat_address="${nat_address#[}"
nat_address="${nat_address%]}"
[[ "$viewer_host" == "$nat_address" ]] || die "GHOSTLIGHT_VIEWER_URL host ($viewer_host) and NEKO_WEBRTC_NAT1TO1 ($nat_address) must match"

docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" config --quiet \
  || die "Compose config is invalid; run 'docker compose --env-file $ENV_FILE -f $COMPOSE_FILE config' for details"

[[ -d "$CONTROL_DIR" ]] || die "control source is missing at $CONTROL_DIR; check out the control API beside runtime"
[[ -f "$CONTROL_DIR/Dockerfile" ]] || die "control/Dockerfile is missing; the control service must be buildable from ../control"

if [[ ! -e "$PROFILE_DIR" ]]; then
  mkdir -p "$(dirname -- "$PROFILE_DIR")"
  chmod 750 "$(dirname -- "$PROFILE_DIR")"
  mkdir -m 700 "$PROFILE_DIR"
fi
[[ -d "$PROFILE_DIR" ]] || die "Chromium profile path is not a directory: $PROFILE_DIR"
[[ ! -L "$PROFILE_DIR" ]] || die "Chromium profile directory must not be a symlink: $PROFILE_DIR"
profile_mode="$(stat_mode "$PROFILE_DIR")"
[[ "$profile_mode" == 700 ]] || die "Chromium profile directory must have mode 700; use chmod 700 $PROFILE_DIR"

if [[ "${GHOSTLIGHT_SKIP_PROFILE_RUNTIME_CHECK:-0}" != 1 ]]; then
  neko_image="$(env_value NEKO_IMAGE)"
  [[ "$neko_image" == *@sha256:* ]] || die "NEKO_IMAGE must be digest-pinned before checking profile write access"
  marker=".ghostlight-preflight-write"
  docker run --rm --user 1000:1000 --entrypoint /bin/sh \
    -v "$PROFILE_DIR:/profile" "$neko_image" \
    -c "set -eu; test -w /profile; umask 077; : > /profile/$marker; rm -f /profile/$marker" \
    || die "viewer runtime identity uid 1000 cannot write $PROFILE_DIR"
fi

printf 'preflight passed: explicit bind address, private environment permissions, Compose config, viewer URL alignment, and uid 1000 profile write access\n'
