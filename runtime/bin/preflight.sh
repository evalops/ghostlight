#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
COMPOSE_FILE="$RUNTIME_DIR/docker-compose.yml"
EXAMPLE_ENV="$RUNTIME_DIR/.env.example"
ENV_FILE="${GHOSTLIGHT_ENV_FILE:-$RUNTIME_DIR/.env}"
CONTROL_DIR="$RUNTIME_DIR/../control"

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

http_url_host() {
  local key="$1"
  local raw="$2"

  python3 - "$raw" <<'PY' \
    || die "$key must use an absolute HTTP or HTTPS URL without credentials or a fragment"
import sys
from urllib.parse import urlsplit

raw = sys.argv[1]
if any(ord(character) < 0x20 or ord(character) == 0x7F for character in raw):
    raise SystemExit(1)
try:
    parsed = urlsplit(raw)
    parsed.port
except ValueError:
    raise SystemExit(1)
if (
    parsed.scheme.lower() not in ("http", "https")
    or not parsed.netloc
    or not parsed.hostname
    or parsed.username is not None
    or parsed.password is not None
    or parsed.fragment
):
    raise SystemExit(1)
print(parsed.hostname)
PY
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
require_command python3

[[ -f "$COMPOSE_FILE" ]] || die "missing $COMPOSE_FILE"
[[ -f "$EXAMPLE_ENV" ]] || die "missing $EXAMPLE_ENV"
[[ -f "$ENV_FILE" ]] || die "create runtime/.env with 'cp runtime/.env.example runtime/.env', then replace every __GENERATE_AT_INSTALL__ value"
[[ ! -L "$ENV_FILE" ]] || die "runtime/.env must not be a symlink"

env_mode="$(stat_mode "$ENV_FILE")"
[[ "$env_mode" == 600 ]] || die "runtime/.env must have mode 600; use chmod 600 runtime/.env"

if "$SCRIPT_DIR/find-placeholders.sh" "$ENV_FILE"; then
  die "runtime/.env still contains install-time placeholders; generate passwords and set the reachable viewer address"
fi

while IFS= read -r env_key; do
  if [[ -v "$env_key" ]]; then
    file_value="$(env_value "$env_key")"
    shell_value="${!env_key}"
    [[ "$shell_value" == "$file_value" ]] \
      || die "shell environment overrides $env_key from runtime/.env; unset $env_key or make the values identical"
  fi
done < <(awk -F= '
  $0 !~ /^[[:space:]]*#/ && $1 ~ /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*$/ {
    key = $1
    gsub(/[[:space:]]/, "", key)
    print key
  }
' "$ENV_FILE")

profile_setting="${CHROMIUM_PROFILE_DIR:-$(env_value CHROMIUM_PROFILE_DIR)}"
profile_setting="${profile_setting:-./data/chromium}"
case "$profile_setting" in
  /*) PROFILE_DIR="$profile_setting" ;;
  *) PROFILE_DIR="$RUNTIME_DIR/${profile_setting#./}" ;;
esac

bind_address="$(env_value GHOSTLIGHT_BIND_ADDRESS)"
[[ -n "$bind_address" ]] || die "GHOSTLIGHT_BIND_ADDRESS must be explicit in runtime/.env"
is_private_bind_address "$bind_address" \
  || die "GHOSTLIGHT_BIND_ADDRESS must be a literal loopback, link-local, or private IP address"

viewer_url="$(env_value GHOSTLIGHT_VIEWER_URL)"
viewer_health_url="$(env_value GHOSTLIGHT_VIEWER_HEALTH_URL)"
nat_address="$(env_value NEKO_WEBRTC_NAT1TO1)"
[[ -n "$viewer_url" && -n "$viewer_health_url" && -n "$nat_address" ]] \
  || die "GHOSTLIGHT_VIEWER_URL, GHOSTLIGHT_VIEWER_HEALTH_URL, and NEKO_WEBRTC_NAT1TO1 must be configured"

viewer_host="$(http_url_host GHOSTLIGHT_VIEWER_URL "$viewer_url")"
http_url_host GHOSTLIGHT_VIEWER_HEALTH_URL "$viewer_health_url" >/dev/null
nat_address="${nat_address#[}"
nat_address="${nat_address%]}"
[[ "$viewer_host" == "$nat_address" ]] || die "GHOSTLIGHT_VIEWER_URL host ($viewer_host) and NEKO_WEBRTC_NAT1TO1 ($nat_address) must match"

rendered_config="$(mktemp "${TMPDIR:-/tmp}/ghostlight-compose.XXXXXX.json")"
chmod 600 "$rendered_config"
cleanup_preflight() {
  rm -f -- "$rendered_config"
}
trap cleanup_preflight EXIT
docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" config --format json >"$rendered_config" \
  || die "Compose config is invalid; run 'docker compose --env-file $ENV_FILE -f $COMPOSE_FILE config' for details"
python3 - "$ENV_FILE" "$rendered_config" <<'PY' \
  || die "rendered Compose config differs from the validated runtime/.env"
import json
import sys


def read_env(path):
    values = {}
    with open(path, encoding="utf-8") as source:
        for raw_line in source:
            line = raw_line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip().strip('"').strip("'")
    return values


expected = read_env(sys.argv[1])
with open(sys.argv[2], encoding="utf-8") as source:
    rendered = json.load(source)
services = rendered.get("services", {})
viewer = services.get("viewer", {})
control = services.get("control", {})

if viewer.get("image") != expected["NEKO_IMAGE"]:
    raise SystemExit(1)
for service in (viewer, control):
    ports = service.get("ports", [])
    if not ports or any(port.get("host_ip") != expected["GHOSTLIGHT_BIND_ADDRESS"] for port in ports):
        raise SystemExit(1)

viewer_environment = viewer.get("environment", {})
control_environment = control.get("environment", {})
viewer_mapping = {
    "NEKO_MEMBER_MULTIUSER_USER_PASSWORD": "NEKO_USER_PASSWORD",
    "NEKO_MEMBER_MULTIUSER_ADMIN_PASSWORD": "NEKO_ADMIN_PASSWORD",
    "NEKO_DESKTOP_SCREEN": "NEKO_DESKTOP_SCREEN",
    "NEKO_CAPTURE_VIDEO_CODEC": "NEKO_CAPTURE_VIDEO_CODEC",
    "NEKO_CAPTURE_VIDEO_PIPELINE": "NEKO_CAPTURE_VIDEO_PIPELINE",
    "NEKO_WEBRTC_UDPMUX": "NEKO_WEBRTC_UDPMUX",
    "NEKO_WEBRTC_TCPMUX": "NEKO_WEBRTC_TCPMUX",
    "NEKO_WEBRTC_ICELITE": "NEKO_WEBRTC_ICELITE",
    "NEKO_WEBRTC_NAT1TO1": "NEKO_WEBRTC_NAT1TO1",
}
control_mapping = {
    "GHOSTLIGHT_VIEWER_URL": "GHOSTLIGHT_VIEWER_URL",
    "GHOSTLIGHT_VIEWER_HEALTH_URL": "GHOSTLIGHT_VIEWER_HEALTH_URL",
}
for rendered_key, env_key in viewer_mapping.items():
    if str(viewer_environment.get(rendered_key)) != expected[env_key]:
        raise SystemExit(1)
for rendered_key, env_key in control_mapping.items():
    if str(control_environment.get(rendered_key)) != expected[env_key]:
        raise SystemExit(1)
PY

[[ -d "$CONTROL_DIR" ]] || die "control source is missing at $CONTROL_DIR; check out the control API beside runtime"
[[ -f "$CONTROL_DIR/Dockerfile" ]] || die "control/Dockerfile is missing; the control service must be buildable from ../control"

if [[ ! -e "$PROFILE_DIR" ]]; then
  mkdir -p "$(dirname -- "$PROFILE_DIR")"
  chmod 750 "$(dirname -- "$PROFILE_DIR")"
  mkdir -m 700 "$PROFILE_DIR"
fi
[[ -d "$PROFILE_DIR" ]] || die "Chromium profile path is not a directory: $PROFILE_DIR"
[[ ! -L "$PROFILE_DIR" ]] || die "Chromium profile directory must not be a symlink: $PROFILE_DIR"
PROFILE_DIR="$(cd -P -- "$PROFILE_DIR" && pwd)"
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
