#!/usr/bin/env bash

set -euo pipefail

RUNTIME_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="$(cd -- "$RUNTIME_DIR/.." && pwd)"

fail() {
  printf 'runtime test failed: %s\n' "$*" >&2
  exit 1
}

assert_file() {
  local path="$1"
  [[ -f "$path" ]] || fail "expected file: $path"
}

assert_contains() {
  local path="$1"
  local needle="$2"
  grep --fixed-strings --line-number -- "$needle" "$path" >/dev/null \
    || fail "expected ${path} to contain: ${needle}"
}

assert_not_contains() {
  local path="$1"
  local needle="$2"
  if grep --fixed-strings --line-number -- "$needle" "$path" >/dev/null; then
    fail "expected ${path} not to contain: ${needle}"
  fi
}

expect_failure() {
  local label="$1"
  shift
  if "$@" >"$root_compose_fixture/failure-output" 2>&1; then
    fail "$label unexpectedly passed"
  fi
}

expect_failure_contains() {
  local label="$1"
  local expected="$2"
  shift 2
  if "$@" >"$root_compose_fixture/failure-output" 2>&1; then
    fail "$label unexpectedly passed"
  fi
  grep --fixed-strings -- "$expected" "$root_compose_fixture/failure-output" >/dev/null \
    || fail "$label failed without expected message: $expected"
}

for path in \
  "$RUNTIME_DIR/docker-compose.yml" \
  "$REPO_DIR/compose.yaml" \
  "$RUNTIME_DIR/.env.example" \
  "$RUNTIME_DIR/chromium-policy.json" \
  "$RUNTIME_DIR/README.md" \
  "$RUNTIME_DIR/bin/find-placeholders.sh" \
  "$RUNTIME_DIR/bin/preflight.sh" \
  "$RUNTIME_DIR/bin/smoke.sh" \
  "$RUNTIME_DIR/bin/profile-backup.sh" \
  "$RUNTIME_DIR/tests/test_profile_backup.sh" \
  "$REPO_DIR/tests/acceptance/run-linux-persistence.sh"; do
  assert_file "$path"
done
assert_file "$REPO_DIR/macos/package-app.sh"

assert_contains "$RUNTIME_DIR/docker-compose.yml" 'ghcr.io/evalops/ghostlight-viewer@sha256:fe135f3553502c1f057fb707c8e9731220d7321376f2eff84b84b4f02a0f7280'
assert_contains "$RUNTIME_DIR/docker-compose.yml" 'context: ../control'
# This is a literal Compose interpolation expression, not a shell expansion.
# shellcheck disable=SC2016
assert_contains "$RUNTIME_DIR/docker-compose.yml" 'host_ip: "${GHOSTLIGHT_BIND_ADDRESS:?set GHOSTLIGHT_BIND_ADDRESS to a private host interface}"'
assert_contains "$RUNTIME_DIR/docker-compose.yml" 'target: 8080'
assert_contains "$RUNTIME_DIR/docker-compose.yml" 'shm_size: "2gb"'
assert_contains "$RUNTIME_DIR/docker-compose.yml" 'restart: unless-stopped'
assert_contains "$RUNTIME_DIR/docker-compose.yml" '/home/neko/.config/chromium'
assert_contains "$RUNTIME_DIR/docker-compose.yml" 'ghostlight-downloads:/home/neko/Downloads'
assert_contains "$RUNTIME_DIR/docker-compose.yml" 'hostname: ghostlight-chromium'
assert_contains "$RUNTIME_DIR/docker-compose.yml" '/etc/chromium/policies/managed/policies.json:ro'
assert_contains "$RUNTIME_DIR/docker-compose.yml" 'GHOSTLIGHT_VIEWER_URL'
assert_contains "$RUNTIME_DIR/docker-compose.yml" 'GHOSTLIGHT_VIEWER_HEALTH_URL'
assert_contains "$RUNTIME_DIR/docker-compose.yml" 'GHOSTLIGHT_API_TOKEN'
assert_contains "$RUNTIME_DIR/docker-compose.yml" 'GHOSTLIGHT_BRIDGE_TOKEN'
assert_contains "$RUNTIME_DIR/docker-compose.yml" 'GHOSTLIGHT_STATE_DIR: "/var/lib/ghostlight/state"'
assert_contains "$RUNTIME_DIR/docker-compose.yml" 'ghostlight-control-state:/var/lib/ghostlight/state'
assert_contains "$RUNTIME_DIR/docker-compose.yml" 'ghostlight-control-attachments:/var/lib/ghostlight/attachments'
assert_contains "$RUNTIME_DIR/docker-compose.yml" 'NEKO_SERVER_BIND: "0.0.0.0:8080"'
# These are literal Compose interpolation expressions, not shell expansions.
# shellcheck disable=SC2016
assert_contains "$RUNTIME_DIR/docker-compose.yml" 'NEKO_CAPTURE_VIDEO_CODEC: "${NEKO_CAPTURE_VIDEO_CODEC:-h264}"'
# shellcheck disable=SC2016
assert_contains "$RUNTIME_DIR/docker-compose.yml" 'NEKO_CAPTURE_VIDEO_PIPELINE: "${NEKO_CAPTURE_VIDEO_PIPELINE-ximagesrc display-name={display}'
assert_contains "$RUNTIME_DIR/docker-compose.yml" 'x264enc name=encoder threads=4 bitrate=3072 key-int-max=60 vbv-buf-capacity=3072 byte-stream=true tune=zerolatency speed-preset=veryfast'
assert_contains "$RUNTIME_DIR/docker-compose.yml" 'h264parse config-interval=1 ! video/x-h264,stream-format=byte-stream,profile=constrained-baseline ! appsink name=appsink}'
# shellcheck disable=SC2016
assert_contains "$RUNTIME_DIR/docker-compose.yml" 'NEKO_WEBRTC_ICELITE: "${NEKO_WEBRTC_ICELITE:-1}"'
assert_contains "$RUNTIME_DIR/docker-compose.yml" 'healthcheck:'
assert_contains "$RUNTIME_DIR/docker-compose.yml" 'http://127.0.0.1:8080/health'
assert_contains "$RUNTIME_DIR/docker-compose.yml" '/v1/viewer'
assert_contains "$RUNTIME_DIR/docker-compose.yml" 'http://127.0.0.1:8080/readyz'

assert_contains "$RUNTIME_DIR/.env.example" '__GENERATE_AT_INSTALL__'
assert_contains "$RUNTIME_DIR/.env.example" 'GHOSTLIGHT_VIEWER_HEALTH_URL=http://viewer:8080'
assert_contains "$RUNTIME_DIR/.env.example" 'GHOSTLIGHT_API_TOKEN=__GENERATE_AT_INSTALL__'
assert_contains "$RUNTIME_DIR/.env.example" 'GHOSTLIGHT_BRIDGE_TOKEN=__GENERATE_AT_INSTALL__'
assert_contains "$RUNTIME_DIR/.env.example" 'NEKO_CAPTURE_VIDEO_CODEC=h264'
assert_contains "$RUNTIME_DIR/.env.example" 'NEKO_WEBRTC_ICELITE=1'
assert_contains "$RUNTIME_DIR/.env.example" 'NEKO_CAPTURE_VIDEO_PIPELINE=ximagesrc display-name={display}'
# These are literal shell assignments in the acceptance fixture.
# shellcheck disable=SC2016
assert_contains "$REPO_DIR/tests/acceptance/run-linux-persistence.sh" 'GHOSTLIGHT_API_TOKEN=$API_TOKEN'
# shellcheck disable=SC2016
assert_contains "$REPO_DIR/tests/acceptance/run-linux-persistence.sh" 'GHOSTLIGHT_BRIDGE_TOKEN=$BRIDGE_TOKEN'
python3 - "$RUNTIME_DIR/chromium-policy.json" "$REPO_DIR/viewer/extension/manifest.json" <<'PY'
import base64
import hashlib
import json
import sys

with open(sys.argv[1], encoding="utf-8") as policy_file:
    policy = json.load(policy_file)
with open(sys.argv[2], encoding="utf-8") as manifest_file:
    manifest = json.load(manifest_file)

public_key = base64.b64decode(manifest["key"], validate=True)
extension_id = "".join(
    chr(ord("a") + nibble)
    for byte in hashlib.sha256(public_key).digest()[:16]
    for nibble in (byte >> 4, byte & 0x0F)
)

assert policy.get("DefaultCookiesSetting") == 1
assert policy.get("RestoreOnStartup") == 1
assert policy.get("ExtensionInstallBlocklist") == ["*"]
assert extension_id == "okabifedphcnokaehflbkmpfphleoaha"
assert extension_id in policy.get("ExtensionInstallAllowlist", []), (
    f"packaged browser agent {extension_id} must be exempt from the extension blocklist"
)
assert f"{extension_id};{manifest['update_url']}" in policy.get("ExtensionInstallForcelist", []), (
    f"packaged browser agent {extension_id} must be installed from its loopback update source"
)
assert "ExtensionSettings" not in policy
assert policy.get("NativeMessagingBlocklist") == ["*"]
assert policy.get("NativeMessagingAllowlist") == ["org.evalops.ghostlight.browser_agent"]
assert policy.get("NativeMessagingUserLevelHosts") is False
PY
python3 - "$REPO_DIR/viewer/browser-agent.crx" "$REPO_DIR/viewer/extension" <<'PY'
import struct
import sys
import zipfile
from pathlib import Path

crx_path = Path(sys.argv[1])
source_dir = Path(sys.argv[2])
with crx_path.open("rb") as crx_file:
    assert crx_file.read(4) == b"Cr24", "browser agent is not a CRX package"
    assert struct.unpack("<I", crx_file.read(4))[0] == 3, "browser agent must use CRX3"
    header_size = struct.unpack("<I", crx_file.read(4))[0]
    crx_file.seek(header_size, 1)
    with zipfile.ZipFile(crx_file) as package:
        packaged = {
            name: package.read(name)
            for name in package.namelist()
            if not name.endswith("/")
        }

source = {
    path.relative_to(source_dir).as_posix(): path.read_bytes()
    for path in source_dir.rglob("*")
    if path.is_file()
}
assert packaged == source, "signed browser-agent CRX must exactly match viewer/extension"
PY
assert_contains "$REPO_DIR/viewer/Dockerfile" 'COPY browser-agent.crx /opt/ghostlight/browser-agent.crx'
assert_contains "$REPO_DIR/viewer/Dockerfile" 'COPY extension/manifest.json /opt/ghostlight/browser-agent-manifest.json'
assert_contains "$REPO_DIR/viewer/Dockerfile" 'COPY browser-agent-updates.xml /opt/ghostlight/browser-agent-updates.xml'
assert_not_contains "$REPO_DIR/viewer/Dockerfile" '/usr/share/chromium/extensions/okabifedphcnokaehflbkmpfphleoaha.json'
assert_contains "$REPO_DIR/viewer/Dockerfile" 'COPY browser-agent-update-server.conf /etc/neko/supervisord/ghostlight-browser-agent-update-server.conf'
assert_contains "$REPO_DIR/viewer/Dockerfile" 'COPY chromium-launch.sh /usr/local/bin/ghostlight-chromium'
assert_contains "$REPO_DIR/viewer/chromium.conf" 'command=/usr/local/bin/ghostlight-chromium'
assert_contains "$REPO_DIR/viewer/chromium-launch.sh" '--extensions-update-frequency=30'
assert_contains "$REPO_DIR/viewer/chromium-launch.sh" '/opt/ghostlight/browser-agent.version'
# shellcheck disable=SC2016
assert_contains "$REPO_DIR/viewer/chromium-launch.sh" 'if [ "$chromium_running" -eq 0 ]'
# shellcheck disable=SC2016
assert_contains "$REPO_DIR/viewer/chromium-launch.sh" 'rm -f -- "$profile_root/SingletonCookie" "$profile_root/SingletonLock" "$profile_root/SingletonSocket"'
# shellcheck disable=SC2016
assert_not_contains "$REPO_DIR/viewer/chromium-launch.sh" 'rm -rf -- "$profile_root"'
# shellcheck disable=SC2016
assert_contains "$REPO_DIR/viewer/chromium-launch.sh" '${expected_version}_*'
# shellcheck disable=SC2016
assert_contains "$REPO_DIR/viewer/chromium-launch.sh" 'find "$extension_root" -mindepth 1 -maxdepth 1 -type d ! -name "${expected_version}_*" -exec rm -rf -- {} +'
assert_not_contains "$REPO_DIR/viewer/chromium-launch.sh" '/home/neko/.config/chromium/Default/Extensions -mindepth'
assert_contains "$REPO_DIR/viewer/Dockerfile" '16af7aa8968c328434526b4c06d8e542571e1600d90d2cedd0349516c96be21b  /etc/chromium.d/extensions'
assert_contains "$REPO_DIR/viewer/Dockerfile" 'rm /etc/chromium.d/extensions'
python3 - "$REPO_DIR/viewer/extension/manifest.json" "$REPO_DIR/viewer/browser-agent-updates.xml" "$REPO_DIR/tests/acceptance/fixtures/browser-agent-0.1.0-external.json" "$REPO_DIR/tests/acceptance/fixtures/browser-agent-0.1.0-policy.json" <<'PY'
import json
import sys
import xml.etree.ElementTree as ET

manifest = json.load(open(sys.argv[1], encoding="utf-8"))
update = ET.parse(sys.argv[2]).getroot().find("{http://www.google.com/update2/response}app/{http://www.google.com/update2/response}updatecheck")
upgrade_source = json.load(open(sys.argv[3], encoding="utf-8"))
upgrade_policy = json.load(open(sys.argv[4], encoding="utf-8"))
assert manifest["version"] == "0.1.1"
assert manifest["update_url"] == "http://127.0.0.1:18084/browser-agent-updates.xml"
assert update.attrib == {
    "codebase": "http://127.0.0.1:18084/browser-agent.crx",
    "version": manifest["version"],
}
assert upgrade_source["external_version"] == "0.1.0"
assert upgrade_policy["ExtensionInstallBlocklist"] == ["*"]
assert "ExtensionSettings" not in upgrade_policy
PY
assert_contains "$REPO_DIR/viewer/browser-agent-update-server.conf" '--bind 127.0.0.1'
assert_contains "$REPO_DIR/viewer/browser-agent-update-server.conf" '--directory /opt/ghostlight'
assert_not_contains "$REPO_DIR/tests/acceptance/run-linux-persistence.sh" 'fixtures/chromium.conf:/etc/neko/supervisord/chromium.conf'
assert_contains "$REPO_DIR/tests/acceptance/run-linux-persistence.sh" 'chromium-cdp-flags:/etc/chromium.d/zz-ghostlight-acceptance:ro'
assert_contains "$REPO_DIR/tests/acceptance/fixtures/chromium-cdp-flags" '--remote-debugging-address=127.0.0.1 --remote-debugging-port=9222 --remote-allow-origins=*'
assert_contains "$REPO_DIR/tests/acceptance/run-linux-persistence.sh" "grep -Fx -- '--enable-remote-extensions'"
assert_contains "$REPO_DIR/tests/acceptance/run-linux-persistence.sh" "grep -Fx -- '--disable-extensions-except='"
assert_contains "$REPO_DIR/tests/acceptance/run-linux-persistence.sh" 'default Chromium launch injected --load-extension'
# shellcheck disable=SC2016
assert_contains "$REPO_DIR/tests/acceptance/run-linux-persistence.sh" '${phase}-chromium-argv.txt'
# shellcheck disable=SC2016
assert_contains "$REPO_DIR/tests/acceptance/run-linux-persistence.sh" '${phase}-browser-agent-installation.txt'
assert_contains "$REPO_DIR/tests/acceptance/run-linux-persistence.sh" 'test ! -e /etc/chromium.d/extensions'
assert_contains "$REPO_DIR/tests/acceptance/run-linux-persistence.sh" 'verify_browser_agent_bridge before'
assert_contains "$REPO_DIR/tests/acceptance/run-linux-persistence.sh" 'verify_browser_agent_bridge after'
assert_contains "$REPO_DIR/tests/acceptance/run-linux-persistence.sh" 'record_browser_agent_installation upgrade-source 0.1.0'
assert_contains "$REPO_DIR/tests/acceptance/run-linux-persistence.sh" 'record_browser_agent_installation before 0.1.1'
assert_contains "$REPO_DIR/tests/acceptance/run-linux-persistence.sh" 'record_browser_agent_installation after 0.1.1'
# The managed update can restart Chromium. Do not probe CDP until the exact
# extension version is committed to the persistent profile.
python3 - "$REPO_DIR/tests/acceptance/run-linux-persistence.sh" <<'PY'
import sys

source = open(sys.argv[1], encoding="utf-8").read()
for phase in ("before", "after"):
    installation = source.index(f"record_browser_agent_installation {phase} 0.1.1")
    cdp = source.index(f"wait_for_cdp {phase}")
    assert installation < cdp
assert 'value.get("webSocketDebuggerUrl")' in source
assert '${phase}-cdp-version.json' in source
PY
assert_contains "$REPO_DIR/tests/acceptance/run-linux-persistence.sh" 'browser-agent-0.1.0-policy.json:/etc/chromium/policies/managed/policies.json:ro'
assert_contains "$REPO_DIR/tests/acceptance/run-linux-persistence.sh" 'http://127.0.0.1:18084/browser-agent-updates.xml'
assert_contains "$REPO_DIR/tests/acceptance/run-linux-persistence.sh" '/usr/local/bin/ghostlight-native-host'
assert_contains "$REPO_DIR/tests/acceptance/run-linux-persistence.sh" 'failure-diagnostics.txt'
assert_contains "$REPO_DIR/tests/acceptance/run-linux-persistence.sh" 'ghostlight-browser-agent-update-server.log'
assert_contains "$REPO_DIR/tests/acceptance/verify-browser-agent.py" 'parse_time(value["last_heartbeat"]) > phase_started'
assert_contains "$REPO_DIR/tests/acceptance/verify-browser-agent.py" 'value.get("state") == "applied"'
assert_contains "$REPO_DIR/tests/acceptance/verify-browser-agent.py" 'value.get("acknowledged_at")'
assert_contains "$REPO_DIR/tests/acceptance/verify-browser-agent.py" 'value.get("completed_at")'
assert_contains "$REPO_DIR/viewer/extension/service-worker.js" 'alarm.name === reconnectAlarm'
assert_not_contains "$REPO_DIR/viewer/extension/service-worker.js" 'heartbeatAlarm && !nativePort'
echo "74c3b8320852f203ad6d725ded2270b7b70940f438264d95d5538f9df42e7742  $REPO_DIR/tests/acceptance/fixtures/browser-agent-0.1.0.crx" \
  | shasum -a 256 --check --status
[[ ! -e "$REPO_DIR/tests/acceptance/fixtures/chromium.conf" ]] || fail "acceptance must use the baked default Chromium Supervisor config"
for chromium_config in \
  "$REPO_DIR/viewer/chromium.conf" \
  "$RUNTIME_DIR/config/chromium-gpu.conf"; do
  assert_contains "$chromium_config" 'command=/usr/local/bin/ghostlight-chromium'
  assert_contains "$chromium_config" '--enable-remote-extensions'
  assert_not_contains "$chromium_config" '--load-extension='
done
for chromium_config in \
  "$REPO_DIR/viewer/chromium.conf" \
  "$RUNTIME_DIR/config/chromium-gpu.conf"; do
  assert_contains "$chromium_config" 'XDG_CONFIG_HOME="/tmp/ghostlight-chromium/config"'
  assert_contains "$chromium_config" 'XDG_CACHE_HOME="/tmp/ghostlight-chromium/cache"'
done
assert_contains "$REPO_DIR/viewer/native-messaging-host.json" 'chrome-extension://okabifedphcnokaehflbkmpfphleoaha/'
assert_contains "$REPO_DIR/viewer/extension/manifest.json" '"nativeMessaging"'
assert_contains "$REPO_DIR/viewer/extension/manifest.json" '"tabs"'
if grep -Eq '"(debugger|scripting|webRequest|cookies)"' "$REPO_DIR/viewer/extension/manifest.json"; then
  fail "browser agent requests a forbidden broad permission"
fi
assert_contains "$RUNTIME_DIR/README.md" 'Apache-2.0'
assert_contains "$RUNTIME_DIR/README.md" 'UDP'
assert_contains "$RUNTIME_DIR/README.md" 'TCP'
assert_contains "$RUNTIME_DIR/bin/preflight.sh" 'docker compose'
assert_contains "$RUNTIME_DIR/bin/preflight.sh" 'GHOSTLIGHT_BIND_ADDRESS'
assert_contains "$RUNTIME_DIR/bin/preflight.sh" 'uid 1000'
assert_contains "$RUNTIME_DIR/bin/smoke.sh" '/readyz'
assert_contains "$RUNTIME_DIR/bin/smoke.sh" '/v1/viewer'
assert_contains "$RUNTIME_DIR/bin/smoke.sh" '/health'
assert_contains "$RUNTIME_DIR/bin/smoke.sh" 'viewer'
assert_contains "$RUNTIME_DIR/bin/profile-backup.sh" 'checksum'

[[ -x "$RUNTIME_DIR/bin/preflight.sh" ]] || fail "preflight.sh must be executable"
[[ -x "$RUNTIME_DIR/bin/smoke.sh" ]] || fail "smoke.sh must be executable"

placeholder_fixture="$(mktemp)"
root_compose_fixture="$(mktemp -d)"
trap 'rm -f "$placeholder_fixture"; rm -rf "$root_compose_fixture"' EXIT
printf '# __GENERATE_AT_INSTALL__ is allowed in comments\nNEKO_USER_PASSWORD=configured\n' >"$placeholder_fixture"
if "$RUNTIME_DIR/bin/find-placeholders.sh" "$placeholder_fixture"; then
  fail "comment-only placeholder must not block a configured environment"
fi
printf 'NEKO_USER_PASSWORD=configured # __GENERATE_AT_INSTALL__ is allowed in an inline comment\n' >"$placeholder_fixture"
if "$RUNTIME_DIR/bin/find-placeholders.sh" "$placeholder_fixture"; then
  fail "inline comment placeholder must not block an unquoted configured value"
fi
printf 'NEKO_USER_PASSWORD="configured" # __GENERATE_AT_INSTALL__ is allowed after a quoted value\n' >"$placeholder_fixture"
if "$RUNTIME_DIR/bin/find-placeholders.sh" "$placeholder_fixture"; then
  fail "inline comment placeholder must not block a quoted configured value"
fi
printf 'NEKO_USER_PASSWORD=__GENERATE_AT_INSTALL__\n' >"$placeholder_fixture"
"$RUNTIME_DIR/bin/find-placeholders.sh" "$placeholder_fixture" >/dev/null \
  || fail "assignment placeholder must be detected"
printf 'NEKO_USER_PASSWORD="__GENERATE_AT_INSTALL__" # configured later\n' >"$placeholder_fixture"
"$RUNTIME_DIR/bin/find-placeholders.sh" "$placeholder_fixture" >/dev/null \
  || fail "quoted assignment placeholder must be detected"

fake_bin="$root_compose_fixture/bin"
profile_fixture="$root_compose_fixture/profile"
env_fixture="$root_compose_fixture/runtime.env"
docker_log="$root_compose_fixture/docker.log"
curl_log="$root_compose_fixture/curl.log"
mkdir -p "$fake_bin"
mkdir -m 700 "$profile_fixture"
# These are literal lines in the generated fake Docker script.
# shellcheck disable=SC2016
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "%s\n" "$*" >>"${FAKE_DOCKER_LOG:?}"' \
  'if [[ "$*" == *"config --format json"* ]]; then' \
  '  cat <<'\''JSON'\''' \
  '{"services":{"viewer":{"image":"ghcr.io/evalops/ghostlight-viewer@sha256:fe135f3553502c1f057fb707c8e9731220d7321376f2eff84b84b4f02a0f7280","ports":[{"host_ip":"127.0.0.1"}],"environment":{"NEKO_MEMBER_MULTIUSER_USER_PASSWORD":"test-user-password","NEKO_MEMBER_MULTIUSER_ADMIN_PASSWORD":"test-admin-password","NEKO_DESKTOP_SCREEN":"1920x1080@30","NEKO_CAPTURE_VIDEO_CODEC":"h264","NEKO_CAPTURE_VIDEO_PIPELINE":"ximagesrc display-name={display} show-pointer=false use-damage=false ! video/x-raw,framerate=30/1 ! videoconvert ! queue ! video/x-raw,format=NV12 ! x264enc name=encoder threads=4 bitrate=3072 key-int-max=60 vbv-buf-capacity=3072 byte-stream=true tune=zerolatency speed-preset=veryfast ! h264parse config-interval=1 ! video/x-h264,stream-format=byte-stream,profile=constrained-baseline ! appsink name=appsink","NEKO_WEBRTC_UDPMUX":"52000","NEKO_WEBRTC_TCPMUX":"52000","NEKO_WEBRTC_ICELITE":"1","NEKO_WEBRTC_NAT1TO1":"127.0.0.1","GHOSTLIGHT_BRIDGE_TOKEN":"bridge-test-secret"}},"control":{"ports":[{"host_ip":"127.0.0.1"}],"environment":{"GHOSTLIGHT_VIEWER_URL":"http://127.0.0.1:8081","GHOSTLIGHT_VIEWER_HEALTH_URL":"http://viewer:8080","GHOSTLIGHT_API_TOKEN":"api-test-secret","GHOSTLIGHT_BRIDGE_TOKEN":"bridge-test-secret"}}}}' \
  'JSON' \
  '  exit 0' \
  'fi' \
  'if [[ "${1:-}" == run && "${FAKE_DOCKER_FAIL_RUN:-0}" == 1 ]]; then exit 1; fi' \
  'exit 0' >"$fake_bin/docker"
chmod 700 "$fake_bin/docker"
# These are literal lines in the generated fake curl script.
# shellcheck disable=SC2016
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'url="${!#}"' \
  'printf "%s\n" "$url" >>"${FAKE_CURL_LOG:?}"' \
  'case "$url" in' \
  '  http://192.168.50.20:8080/healthz) printf '\''{"status":"ok"}\n'\'' ;;' \
  '  http://192.168.50.20:8080/readyz) printf '\''{"viewer":"ready"}\n'\'' ;;' \
  '  http://192.168.50.20:8080/v1/viewer) printf '\''{"viewer_url":"http://192.168.50.20:8081/session?mode=control"}\n'\'' ;;' \
  '  http://192.168.50.20:8081/health) printf '\''{"status":"ok"}\n'\'' ;;' \
  '  http://192.168.50.20:8080/v1/workspaces) printf '\''[{"id":"default"}]\n'\'' ;;' \
  '  http://192.168.50.20:8080/v1/bridge/bootstrap) printf '\''{"session_id":"default"}\n'\'' ;;' \
  '  *) exit 22 ;;' \
  'esac' >"$fake_bin/curl"
chmod 700 "$fake_bin/curl"
sed \
  -e 's|GHOSTLIGHT_BIND_ADDRESS=.*|GHOSTLIGHT_BIND_ADDRESS=127.0.0.1|' \
  -e 's|GHOSTLIGHT_VIEWER_URL=.*|GHOSTLIGHT_VIEWER_URL=http://127.0.0.1:8081|' \
  -e 's|NEKO_USER_PASSWORD=.*|NEKO_USER_PASSWORD=test-user-password|' \
  -e 's|NEKO_ADMIN_PASSWORD=.*|NEKO_ADMIN_PASSWORD=test-admin-password|' \
  -e 's|GHOSTLIGHT_API_TOKEN=.*|GHOSTLIGHT_API_TOKEN=api-test-secret|' \
  -e 's|GHOSTLIGHT_BRIDGE_TOKEN=.*|GHOSTLIGHT_BRIDGE_TOKEN=bridge-test-secret|' \
  -e 's|NEKO_WEBRTC_NAT1TO1=.*|NEKO_WEBRTC_NAT1TO1=127.0.0.1|' \
  "$RUNTIME_DIR/.env.example" >"$env_fixture"
chmod 600 "$env_fixture"
PATH="$fake_bin:$PATH" GHOSTLIGHT_ENV_FILE="$env_fixture" CHROMIUM_PROFILE_DIR="$profile_fixture" \
  FAKE_DOCKER_LOG="$docker_log" "$RUNTIME_DIR/bin/preflight.sh" >/dev/null
grep --fixed-strings -- 'run --rm --user 1000:1000' "$docker_log" >/dev/null \
  || fail "preflight must verify profile writability as viewer uid 1000"
expect_failure "shell environment Compose override" env PATH="$fake_bin:$PATH" GHOSTLIGHT_ENV_FILE="$env_fixture" \
  CHROMIUM_PROFILE_DIR="$profile_fixture" GHOSTLIGHT_BIND_ADDRESS=0.0.0.0 FAKE_DOCKER_LOG="$docker_log" \
  GHOSTLIGHT_SKIP_PROFILE_RUNTIME_CHECK=1 "$RUNTIME_DIR/bin/preflight.sh"
expect_failure "uid 1000 profile write denial" env PATH="$fake_bin:$PATH" GHOSTLIGHT_ENV_FILE="$env_fixture" \
  CHROMIUM_PROFILE_DIR="$profile_fixture" FAKE_DOCKER_LOG="$docker_log" FAKE_DOCKER_FAIL_RUN=1 "$RUNTIME_DIR/bin/preflight.sh"

chmod 640 "$env_fixture"
expect_failure "group-readable environment" env PATH="$fake_bin:$PATH" GHOSTLIGHT_ENV_FILE="$env_fixture" \
  CHROMIUM_PROFILE_DIR="$profile_fixture" FAKE_DOCKER_LOG="$docker_log" GHOSTLIGHT_SKIP_PROFILE_RUNTIME_CHECK=1 "$RUNTIME_DIR/bin/preflight.sh"
chmod 600 "$env_fixture"
sed -i.bak 's|GHOSTLIGHT_BIND_ADDRESS=127.0.0.1|GHOSTLIGHT_BIND_ADDRESS=0.0.0.0|' "$env_fixture"
rm "$env_fixture.bak"
expect_failure "wildcard bind address" env PATH="$fake_bin:$PATH" GHOSTLIGHT_ENV_FILE="$env_fixture" \
  CHROMIUM_PROFILE_DIR="$profile_fixture" FAKE_DOCKER_LOG="$docker_log" GHOSTLIGHT_SKIP_PROFILE_RUNTIME_CHECK=1 "$RUNTIME_DIR/bin/preflight.sh"
sed -i.bak 's|GHOSTLIGHT_BIND_ADDRESS=0.0.0.0|GHOSTLIGHT_BIND_ADDRESS=127.0.0.1|' "$env_fixture"
rm "$env_fixture.bak"
chmod 750 "$profile_fixture"
expect_failure "group-readable profile" env PATH="$fake_bin:$PATH" GHOSTLIGHT_ENV_FILE="$env_fixture" \
  CHROMIUM_PROFILE_DIR="$profile_fixture" FAKE_DOCKER_LOG="$docker_log" GHOSTLIGHT_SKIP_PROFILE_RUNTIME_CHECK=1 "$RUNTIME_DIR/bin/preflight.sh"
chmod 700 "$profile_fixture"

invalid_viewer_env="$root_compose_fixture/invalid-viewer.env"
sed 's|GHOSTLIGHT_VIEWER_URL=.*|GHOSTLIGHT_VIEWER_URL=ftp://127.0.0.1:8081|' "$env_fixture" >"$invalid_viewer_env"
chmod 600 "$invalid_viewer_env"
expect_failure_contains "control-rejected viewer URL" "GHOSTLIGHT_VIEWER_URL must use an absolute HTTP or HTTPS URL" \
  env PATH="$fake_bin:$PATH" GHOSTLIGHT_ENV_FILE="$invalid_viewer_env" CHROMIUM_PROFILE_DIR="$profile_fixture" \
  FAKE_DOCKER_LOG="$docker_log" GHOSTLIGHT_SKIP_PROFILE_RUNTIME_CHECK=1 "$RUNTIME_DIR/bin/preflight.sh"

invalid_health_env="$root_compose_fixture/invalid-health.env"
sed 's|GHOSTLIGHT_VIEWER_HEALTH_URL=.*|GHOSTLIGHT_VIEWER_HEALTH_URL=file:///tmp/viewer|' "$env_fixture" >"$invalid_health_env"
chmod 600 "$invalid_health_env"
expect_failure_contains "control-rejected health URL" "GHOSTLIGHT_VIEWER_HEALTH_URL must use an absolute HTTP or HTTPS URL" \
  env PATH="$fake_bin:$PATH" GHOSTLIGHT_ENV_FILE="$invalid_health_env" CHROMIUM_PROFILE_DIR="$profile_fixture" \
  FAKE_DOCKER_LOG="$docker_log" GHOSTLIGHT_SKIP_PROFILE_RUNTIME_CHECK=1 "$RUNTIME_DIR/bin/preflight.sh"

equal_tokens_env="$root_compose_fixture/equal-tokens.env"
sed 's|GHOSTLIGHT_BRIDGE_TOKEN=.*|GHOSTLIGHT_BRIDGE_TOKEN=api-test-secret|' "$env_fixture" >"$equal_tokens_env"
chmod 600 "$equal_tokens_env"
expect_failure_contains "equal control and bridge tokens" "GHOSTLIGHT_API_TOKEN and GHOSTLIGHT_BRIDGE_TOKEN must be different" \
  env PATH="$fake_bin:$PATH" GHOSTLIGHT_ENV_FILE="$equal_tokens_env" CHROMIUM_PROFILE_DIR="$profile_fixture" \
  FAKE_DOCKER_LOG="$docker_log" GHOSTLIGHT_SKIP_PROFILE_RUNTIME_CHECK=1 "$RUNTIME_DIR/bin/preflight.sh"

canonical_profile_fixture="$(cd -P -- "$profile_fixture" && pwd)"
relative_profile_fixture="$(python3 - "$RUNTIME_DIR" "$canonical_profile_fixture" <<'PY'
import os
import sys

print(os.path.relpath(sys.argv[2], sys.argv[1]))
PY
)"
profile_env_fixture="$root_compose_fixture/profile-from-env.env"
cp "$env_fixture" "$profile_env_fixture"
printf 'CHROMIUM_PROFILE_DIR=%s\n' "$relative_profile_fixture" >>"$profile_env_fixture"
chmod 600 "$profile_env_fixture"
: >"$docker_log"
PATH="$fake_bin:$PATH" GHOSTLIGHT_ENV_FILE="$profile_env_fixture" FAKE_DOCKER_LOG="$docker_log" \
  "$RUNTIME_DIR/bin/preflight.sh" >/dev/null
grep --fixed-strings -- "-v $canonical_profile_fixture:/profile" "$docker_log" >/dev/null \
  || fail "preflight must validate the env-file profile directory that Compose mounts"

smoke_env_fixture="$root_compose_fixture/smoke.env"
sed \
  -e 's|GHOSTLIGHT_BIND_ADDRESS=.*|GHOSTLIGHT_BIND_ADDRESS=192.168.50.20|' \
  -e 's|GHOSTLIGHT_VIEWER_URL=.*|GHOSTLIGHT_VIEWER_URL=http://192.168.50.20:8081/session?mode=control|' \
  -e 's|NEKO_WEBRTC_NAT1TO1=.*|NEKO_WEBRTC_NAT1TO1=192.168.50.20|' \
  "$env_fixture" >"$smoke_env_fixture"
chmod 600 "$smoke_env_fixture"
: >"$curl_log"
PATH="$fake_bin:$PATH" GHOSTLIGHT_ENV_FILE="$smoke_env_fixture" FAKE_DOCKER_LOG="$docker_log" \
  FAKE_CURL_LOG="$curl_log" SMOKE_ATTEMPTS=1 "$RUNTIME_DIR/bin/smoke.sh" >/dev/null \
  || fail "smoke must probe the configured private bind and normalize discovered viewer health URLs"
expected_smoke_requests=$'http://192.168.50.20:8080/healthz\nhttp://192.168.50.20:8081/health\nhttp://192.168.50.20:8080/readyz\nhttp://192.168.50.20:8080/v1/viewer\nhttp://192.168.50.20:8081/health\nhttp://192.168.50.20:8080/v1/workspaces\nhttp://192.168.50.20:8080/v1/bridge/bootstrap'
[[ "$(<"$curl_log")" == "$expected_smoke_requests" ]] \
  || fail "smoke requested unexpected URLs: $(tr '\n' ' ' <"$curl_log")"

bash -n "$RUNTIME_DIR/bin/find-placeholders.sh"
bash -n "$RUNTIME_DIR/bin/preflight.sh"
bash -n "$RUNTIME_DIR/bin/smoke.sh"
bash -n "$RUNTIME_DIR/bin/profile-backup.sh"
bash -n "$RUNTIME_DIR/tests/test_profile_backup.sh"
bash -n "$REPO_DIR/macos/package-app.sh"

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "$RUNTIME_DIR/bin/find-placeholders.sh" "$RUNTIME_DIR/bin/preflight.sh" "$RUNTIME_DIR/bin/smoke.sh" "$RUNTIME_DIR/bin/profile-backup.sh" "$RUNTIME_DIR/tests/test_profile_backup.sh" "$REPO_DIR/macos/package-app.sh"
fi

bash "$RUNTIME_DIR/tests/test_profile_backup.sh"

expected_neko_image="$(awk -F= '$1 == "NEKO_IMAGE" { sub(/^[^=]*=/, ""); print; exit }' "$RUNTIME_DIR/.env.example")"
[[ "$expected_neko_image" == *@sha256:* ]] || fail "NEKO_IMAGE in .env.example must be digest-pinned"
resolved_images="$(cd "$RUNTIME_DIR" && docker compose --env-file .env.example -f docker-compose.yml config --images)"
grep --fixed-strings --line-regexp -- "$expected_neko_image" <<<"$resolved_images" >/dev/null \
  || fail "Compose viewer image must resolve to NEKO_IMAGE from .env.example"
(cd "$RUNTIME_DIR" && docker compose --env-file .env.example -f docker-compose.yml config --quiet)

resolved_runtime="$(cd "$RUNTIME_DIR" && docker compose --env-file .env.example -f docker-compose.yml config)"
grep --fixed-strings -- "source: $RUNTIME_DIR/data/chromium" <<<"$resolved_runtime" >/dev/null \
  || fail "Compose viewer profile must resolve to runtime/data/chromium"
grep --fixed-strings -- 'target: /home/neko/.config/chromium' <<<"$resolved_runtime" >/dev/null \
  || fail "Compose viewer profile target must remain the Chromium profile directory"
grep --fixed-strings -- 'target: /etc/chromium/policies/managed/policies.json' <<<"$resolved_runtime" >/dev/null \
  || fail "Compose must mount the persistent Chromium policy"
grep --fixed-strings -- 'NEKO_SERVER_BIND: 0.0.0.0:8080' <<<"$resolved_runtime" >/dev/null \
  || fail "Neko must accept readiness probes from the private Compose network"
grep --fixed-strings -- 'ximagesrc display-name={display} show-pointer=false use-damage=false ! video/x-raw,framerate=30/1 ! videoconvert ! queue ! video/x-raw,format=NV12 ! x264enc name=encoder threads=4 bitrate=3072 key-int-max=60 vbv-buf-capacity=3072 byte-stream=true tune=zerolatency speed-preset=veryfast ! h264parse config-interval=1 ! video/x-h264,stream-format=byte-stream,profile=constrained-baseline ! appsink name=appsink' <<<"$resolved_runtime" >/dev/null \
  || fail "Compose must render the H.264 capture pipeline from .env.example intact"

mkdir -p "$root_compose_fixture/runtime" "$root_compose_fixture/control"
cp "$REPO_DIR/compose.yaml" "$root_compose_fixture/compose.yaml"
cp "$RUNTIME_DIR/docker-compose.yml" "$root_compose_fixture/runtime/docker-compose.yml"
cp "$RUNTIME_DIR/chromium-policy.json" "$root_compose_fixture/runtime/chromium-policy.json"
cp "$RUNTIME_DIR/.env.example" "$root_compose_fixture/runtime/.env"
cp "$REPO_DIR/control/Dockerfile" "$root_compose_fixture/control/Dockerfile"
sed -i.bak \
  -e 's|GHOSTLIGHT_BIND_ADDRESS=.*|GHOSTLIGHT_BIND_ADDRESS=127.0.0.1|' \
  -e 's|GHOSTLIGHT_VIEWER_URL=.*|GHOSTLIGHT_VIEWER_URL=http://192.0.2.10:8081|' \
  -e 's|NEKO_USER_PASSWORD=.*|NEKO_USER_PASSWORD=test-user-password|' \
  -e 's|NEKO_ADMIN_PASSWORD=.*|NEKO_ADMIN_PASSWORD=test-admin-password|' \
  -e 's|NEKO_WEBRTC_NAT1TO1=.*|NEKO_WEBRTC_NAT1TO1=192.0.2.10|' \
  "$root_compose_fixture/runtime/.env"
rm "$root_compose_fixture/runtime/.env.bak"
root_runtime="$(cd "$root_compose_fixture" && docker compose config)"
grep --fixed-strings -- 'GHOSTLIGHT_VIEWER_URL: http://192.0.2.10:8081' <<<"$root_runtime" >/dev/null \
  || fail "flag-free root Compose must load runtime/.env"
grep --fixed-strings -- 'NEKO_MEMBER_MULTIUSER_USER_PASSWORD: test-user-password' <<<"$root_runtime" >/dev/null \
  || fail "flag-free root Compose must configure the viewer password"
grep --fixed-strings -- 'NEKO_WEBRTC_NAT1TO1: 192.0.2.10' <<<"$root_runtime" >/dev/null \
  || fail "flag-free root Compose must configure the reachable WebRTC address"
grep --fixed-strings -- 'host_ip: 127.0.0.1' <<<"$root_runtime" >/dev/null \
  || fail "flag-free root Compose must bind published ports to GHOSTLIGHT_BIND_ADDRESS"

printf 'runtime tests passed\n'
