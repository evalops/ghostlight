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
share_viewer_network="${GHOSTLIGHT_ACCEPTANCE_SHARE_VIEWER_NETWORK:-0}"
# H.264 needs both the codec and a matching pipeline; Neko forces VP8 when the pipeline is empty.
NEKO_VIDEO_CODEC="${GHOSTLIGHT_ACCEPTANCE_VIDEO_CODEC:-h264}"
NEKO_VIDEO_PIPELINE="${GHOSTLIGHT_ACCEPTANCE_VIDEO_PIPELINE:-ximagesrc display-name={display} show-pointer=false use-damage=false ! video/x-raw,framerate=30/1 ! videoconvert ! queue ! video/x-raw,format=NV12 ! x264enc name=encoder threads=4 bitrate=3072 key-int-max=60 vbv-buf-capacity=3072 byte-stream=true tune=zerolatency speed-preset=veryfast ! h264parse config-interval=1 ! video/x-h264,stream-format=byte-stream,profile=constrained-baseline ! appsink name=appsink}"
DEFAULT_NEKO_IMAGE_REF="$(awk -F= '$1 == "NEKO_IMAGE" { sub(/^[^=]*=/, ""); print; exit }' "$ROOT_DIR/runtime/.env.example")"
[[ "$DEFAULT_NEKO_IMAGE_REF" =~ ^ghcr\.io/(m1k1o/neko/chromium|evalops/ghostlight-viewer)@sha256:[0-9a-f]{64}$ ]] || {
  printf 'runtime/.env.example does not contain a canonical Neko image pin\n' >&2
  exit 1
}
NEKO_IMAGE_REF="${NEKO_IMAGE:-$DEFAULT_NEKO_IMAGE_REF}"
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"
[[ "$share_viewer_network" =~ ^[01]$ ]] || {
  printf 'GHOSTLIGHT_ACCEPTANCE_SHARE_VIEWER_NETWORK must be 0 or 1\n' >&2
  exit 1
}
[[ "$SKIP_PROFILE_CHECK" =~ ^[01]$ ]] || {
  printf 'GHOSTLIGHT_ACCEPTANCE_SKIP_PROFILE_CHECK must be 0 or 1\n' >&2
  exit 1
}
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ghostlight-acceptance.XXXXXX")"
PROFILE_DIR="$WORK_DIR/chromium-profile"
ENV_FILE="$WORK_DIR/runtime.env"
OVERRIDE_FILE="$WORK_DIR/compose.override.yml"
UPGRADE_OVERRIDE_FILE="$WORK_DIR/compose.upgrade.override.yml"
TRANSCRIPT="$OUTPUT_DIR/transcript.txt"
SOURCE_SHA="${GHOSTLIGHT_ACCEPTANCE_SOURCE_SHA:-$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || printf unknown)}"
read -r API_TOKEN BRIDGE_TOKEN < <(python3 -c 'import secrets; print(secrets.token_hex(32), secrets.token_hex(32))')
profile_owned_by_viewer=0
export COMPOSE_BAKE="${COMPOSE_BAKE:-false}"

finish() {
  local status=$?
  local cleanup_status=0
  if (( status != 0 )) && [[ -f "$ENV_FILE" && -f "$OVERRIDE_FILE" ]]; then
    docker compose --project-name "$PROJECT" --env-file "$ENV_FILE" -f "$ROOT_DIR/runtime/docker-compose.yml" -f "$OVERRIDE_FILE" \
      exec -T viewer sh -lc '
        printf "%s\n" "--- supervisor ---"
        supervisorctl status
        printf "%s\n" "--- chromium argv ---"
        for cmdline in /proc/[0-9]*/cmdline; do
          [ -r "$cmdline" ] || continue
          tr "\000" "\n" <"$cmdline" | grep -Fx /usr/lib/chromium/chromium >/dev/null || continue
          tr "\000" "\n" <"$cmdline"
          break
        done
        printf "%s\n" "--- update server ---"
        cat /var/log/neko/ghostlight-browser-agent-update-server.log 2>/dev/null || true
        printf "%s\n" "--- chromium ---"
        tail -200 /var/log/neko/chromium.log 2>/dev/null || true
        printf "%s\n" "--- policy ---"
        cat /etc/chromium/policies/managed/policies.json
        printf "%s\n" "--- installed agent versions ---"
        find /home/neko/.config/chromium/Default/Extensions/okabifedphcnokaehflbkmpfphleoaha -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null || true
      ' >"$OUTPUT_DIR/failure-diagnostics.txt" 2>&1 || true
  fi
  if [[ "${GHOSTLIGHT_ACCEPTANCE_KEEP_STACK:-0}" != 1 ]]; then
    if ! docker compose --project-name "$PROJECT" --env-file "$ENV_FILE" -f "$ROOT_DIR/runtime/docker-compose.yml" -f "$OVERRIDE_FILE" down --remove-orphans >>"$TRANSCRIPT" 2>&1; then
      cleanup_status=1
      printf 'cleanup failed; acceptance work directory retained: %s\n' "$WORK_DIR" >&2
    elif (( profile_owned_by_viewer == 1 )) && ! docker run --rm --user 0:0 --entrypoint /bin/sh \
      -v "$PROFILE_DIR:/profile" "$NEKO_IMAGE_REF" \
      -c 'chown -R "$1:$2" /profile' _ "$HOST_UID" "$HOST_GID" >>"$TRANSCRIPT" 2>&1; then
      cleanup_status=1
      printf 'cleanup failed while restoring acceptance profile ownership: %s\n' "$PROFILE_DIR" >&2
    elif ! rm -rf -- "$WORK_DIR"; then
      cleanup_status=1
      printf 'cleanup failed while removing acceptance work directory: %s\n' "$WORK_DIR" >&2
    fi
  else
    printf 'acceptance work directory retained: %s\n' "$WORK_DIR" >&2
  fi
  if (( status == 0 && cleanup_status != 0 )); then
    printf 'cleanup failed; acceptance result changed to failure\n' >&2
    status=$cleanup_status
  fi
  trap - EXIT
  exit "$status"
}
trap finish EXIT

record_chromium_argv() {
  local phase="$1"
  local argv_file="$OUTPUT_DIR/${phase}-chromium-argv.txt"
  docker compose --project-name "$PROJECT" --env-file "$ENV_FILE" -f "$ROOT_DIR/runtime/docker-compose.yml" -f "$OVERRIDE_FILE" \
    exec -T viewer sh -lc '
      for cmdline in /proc/[0-9]*/cmdline; do
        [ -r "$cmdline" ] || continue
        first_arg="$(tr "\000" "\n" <"$cmdline" | sed -n "1p")"
        [ "$first_arg" = /usr/lib/chromium/chromium ] || continue
        tr "\000" "\n" <"$cmdline"
        exit 0
      done
      exit 1
    ' >"$argv_file"
  grep -Fx -- '--remote-debugging-port=9222' "$argv_file" >/dev/null
  grep -Fx -- '--enable-remote-extensions' "$argv_file" >/dev/null
  if grep -Fx -- '--disable-extensions-except=' "$argv_file" >/dev/null; then
    printf 'Debian Chromium wrapper disabled the packaged browser agent; argv: %s\n' "$argv_file" >&2
    return 1
  fi
  if grep -F -- '--load-extension=' "$argv_file" >/dev/null; then
    printf 'default Chromium launch injected --load-extension; argv: %s\n' "$argv_file" >&2
    return 1
  fi
  if grep -F -- '/usr/share/chromium/extensions/okabifedphcnokaehflbkmpfphleoaha.json' "$argv_file" >/dev/null; then
    printf 'external-registration JSON leaked into Chromium argv: %s\n' "$argv_file" >&2
    return 1
  fi
}

record_browser_agent_installation() {
  local phase="$1"
  local expected_version="$2"
  local installation_file="$OUTPUT_DIR/${phase}-browser-agent-installation.txt"
  docker compose --project-name "$PROJECT" --env-file "$ENV_FILE" -f "$ROOT_DIR/runtime/docker-compose.yml" -f "$OVERRIDE_FILE" \
    exec -T viewer sh -lc '
      set -eu
      extension_root=/home/neko/.config/chromium/Default/Extensions/okabifedphcnokaehflbkmpfphleoaha
      expected_version="$1"
      attempt=0
      while [ "$attempt" -lt 60 ]; do
        if python3 -c "import json,sys; value=json.load(open(\"/home/neko/.config/chromium/Default/Preferences\", encoding=\"utf-8\"))[\"extensions\"][\"settings\"][\"okabifedphcnokaehflbkmpfphleoaha\"]; assert value[\"manifest\"][\"version\"] == sys.argv[1]; print(value[\"manifest\"][\"version\"], value.get(\"path\", \"\"))" "$expected_version"; then
          find "$extension_root" -mindepth 1 -maxdepth 1 -type d -name "${expected_version}_*" -print
          exit 0
        fi
        attempt=$((attempt + 1))
        sleep 1
      done
      exit 1
    ' _ "$expected_version" >"$installation_file"
  grep -F -- "$expected_version" "$installation_file" >/dev/null
  grep -F -- "/Default/Extensions/okabifedphcnokaehflbkmpfphleoaha/${expected_version}_" "$installation_file" >/dev/null
}

wait_for_cdp() {
  local phase="$1"
  local version_file="$OUTPUT_DIR/${phase}-cdp-version.json"
  local attempt=0
  while (( attempt < 60 )); do
    if curl --fail --silent --show-error "http://127.0.0.1:$CDP_PORT/json/version" >"$version_file" 2>/dev/null \
      && python3 -c 'import json,sys; value=json.load(open(sys.argv[1], encoding="utf-8")); assert value.get("webSocketDebuggerUrl")' "$version_file"; then
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 1
  done
  printf 'Chromium CDP did not become ready after browser-agent installation: %s\n' "$version_file" >&2
  return 1
}

verify_browser_agent_bridge() {
  local phase="$1"
  local target_url="http://127.0.0.1:18083/bridge-$phase?marker=$MARKER"
  local process_file="$OUTPUT_DIR/${phase}-native-host-process.txt"
  local receipt_file="$OUTPUT_DIR/${phase}-native-bridge.json"
  local update_file="$OUTPUT_DIR/${phase}-browser-agent-update.xml"
  docker compose --project-name "$PROJECT" --env-file "$ENV_FILE" -f "$ROOT_DIR/runtime/docker-compose.yml" -f "$OVERRIDE_FILE" \
    exec -T viewer curl --fail --silent --show-error \
      http://127.0.0.1:18084/browser-agent-updates.xml >"$update_file"
  grep -F -- 'appid="okabifedphcnokaehflbkmpfphleoaha"' "$update_file" >/dev/null
  grep -F -- 'codebase="http://127.0.0.1:18084/browser-agent.crx" version="0.1.1"' "$update_file" >/dev/null
  python3 "$TEST_DIR/verify-browser-agent.py" \
    "http://127.0.0.1:$CONTROL_PORT" "$API_TOKEN" "$target_url" "$phase" "$receipt_file"
  docker compose --project-name "$PROJECT" --env-file "$ENV_FILE" -f "$ROOT_DIR/runtime/docker-compose.yml" -f "$OVERRIDE_FILE" \
    exec -T viewer sh -lc '
      for cmdline in /proc/[0-9]*/cmdline; do
        [ -r "$cmdline" ] || continue
        first_arg="$(tr "\000" "\n" <"$cmdline" | sed -n "1p")"
        [ "$first_arg" = /usr/local/bin/ghostlight-native-host ] || continue
        tr "\000" "\n" <"$cmdline"
        exit 0
      done
      exit 1
    ' >"$process_file"
  grep -Fx -- /usr/local/bin/ghostlight-native-host "$process_file" >/dev/null
  grep -Fx -- 'chrome-extension://okabifedphcnokaehflbkmpfphleoaha/' "$process_file" >/dev/null
}

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
NEKO_DESKTOP_SCREEN=1920x1080@30
NEKO_CAPTURE_VIDEO_CODEC=$NEKO_VIDEO_CODEC
NEKO_CAPTURE_VIDEO_PIPELINE=$NEKO_VIDEO_PIPELINE
NEKO_WEBRTC_UDPMUX=$WEBRTC_PORT
NEKO_WEBRTC_TCPMUX=$WEBRTC_PORT
NEKO_WEBRTC_ICELITE=0
NEKO_WEBRTC_NAT1TO1=127.0.0.1
GHOSTLIGHT_VIEWER_URL=http://127.0.0.1:$VIEWER_PORT
GHOSTLIGHT_VIEWER_HEALTH_URL=http://viewer:8080
GHOSTLIGHT_API_TOKEN=$API_TOKEN
GHOSTLIGHT_BRIDGE_TOKEN=$BRIDGE_TOKEN
NEKO_IMAGE=$NEKO_IMAGE_REF
EOF
chmod 600 "$ENV_FILE"

shared_viewer_port=''
if (( share_viewer_network == 1 )); then
  shared_viewer_port="$(cat <<EOF
      - target: 8082
        published: "$CONTROL_PORT"
        host_ip: 127.0.0.1
        protocol: tcp
EOF
)"
fi

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
$shared_viewer_port
    environment:
      GHOSTLIGHT_ACCEPTANCE_MARKER: "$MARKER"
    volumes:
      - "$FIXTURE_DIR/chromium-cdp-flags:/etc/chromium.d/zz-ghostlight-acceptance:ro"
      - "$FIXTURE_DIR/cdp_proxy.py:/usr/local/bin/ghostlight-cdp-proxy.py:ro"
      - "$FIXTURE_DIR/cdp_proxy.conf:/etc/neko/supervisord/ghostlight-cdp-proxy.conf:ro"
      - "$FIXTURE_DIR/synthetic_server.py:/usr/local/bin/ghostlight-synthetic-server.py:ro"
      - "$FIXTURE_DIR/synthetic_server.conf:/etc/neko/supervisord/ghostlight-synthetic-server.conf:ro"
  control:
    security_opt:
      - apparmor=unconfined
EOF

cat >"$UPGRADE_OVERRIDE_FILE" <<EOF
services:
  viewer:
    volumes:
      - "$FIXTURE_DIR/browser-agent-0.1.0.crx:/opt/ghostlight/browser-agent.crx:ro"
      - "$FIXTURE_DIR/browser-agent-0.1.0-external.json:/usr/share/chromium/extensions/okabifedphcnokaehflbkmpfphleoaha.json:ro"
      - "$FIXTURE_DIR/browser-agent-0.1.0-policy.json:/etc/chromium/policies/managed/policies.json:ro"
EOF

if (( share_viewer_network == 1 )); then
  cat >>"$OVERRIDE_FILE" <<EOF
    # The nested acceptance host drops sibling-container bridge traffic. Sharing the
    # viewer namespace keeps the readiness request inside loopback for this opt-in mode.
    network_mode: "service:viewer"
    ports: !reset []
    environment:
      GHOSTLIGHT_LISTEN_ADDR: "0.0.0.0:8082"
      GHOSTLIGHT_VIEWER_HEALTH_URL: "http://127.0.0.1:8080"
    healthcheck:
      test: ["CMD-SHELL", "wget -q -O /dev/null http://127.0.0.1:8082/readyz || exit 1"]
EOF
fi

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

  npm ci --prefix "$TEST_DIR"
  preflight_profile_check="$SKIP_PROFILE_CHECK"
  if (( HOST_UID != 1000 )); then
    # Preflight must resolve the mode-0700 host path before ownership transfers
    # to Neko. The direct container check below preserves the same write proof.
    preflight_profile_check=1
  fi
  GHOSTLIGHT_ENV_FILE="$ENV_FILE" CHROMIUM_PROFILE_DIR="$PROFILE_DIR" GHOSTLIGHT_SKIP_PROFILE_RUNTIME_CHECK="$preflight_profile_check" "$ROOT_DIR/runtime/bin/preflight.sh"
  if (( HOST_UID != 1000 )); then
    profile_owned_by_viewer=1
    docker run --rm --user 0:0 --entrypoint /bin/sh \
      -v "$PROFILE_DIR:/profile" "$NEKO_IMAGE_REF" \
      -c 'set -eu; chown 1000:1000 /profile; chmod 700 /profile'
  fi
  if (( SKIP_PROFILE_CHECK == 0 )); then
    docker run --rm --user 1000:1000 --entrypoint /bin/sh \
      -v "$PROFILE_DIR:/profile" "$NEKO_IMAGE_REF" \
      -c 'set -eu; test -w /profile; umask 077; : > /profile/.ghostlight-acceptance-write; rm -f /profile/.ghostlight-acceptance-write'
  fi
  docker compose --project-name "$PROJECT" --env-file "$ENV_FILE" -f "$ROOT_DIR/runtime/docker-compose.yml" -f "$OVERRIDE_FILE" -f "$UPGRADE_OVERRIDE_FILE" up --detach --build --wait --wait-timeout 120

  record_browser_agent_installation upgrade-source 0.1.0
  docker compose --project-name "$PROJECT" --env-file "$ENV_FILE" -f "$ROOT_DIR/runtime/docker-compose.yml" -f "$OVERRIDE_FILE" -f "$UPGRADE_OVERRIDE_FILE" down
  docker compose --project-name "$PROJECT" --env-file "$ENV_FILE" -f "$ROOT_DIR/runtime/docker-compose.yml" -f "$OVERRIDE_FILE" up --detach --build --wait --wait-timeout 120

  record_browser_agent_installation before 0.1.1
  wait_for_cdp before
  docker compose --project-name "$PROJECT" --env-file "$ENV_FILE" -f "$ROOT_DIR/runtime/docker-compose.yml" -f "$OVERRIDE_FILE" \
    exec -T viewer sh -lc 'test ! -e /etc/chromium.d/extensions; test -f /usr/share/chromium/extensions/okabifedphcnokaehflbkmpfphleoaha.json'
  record_chromium_argv before

  node "$TEST_DIR/persistence.mjs" "http://127.0.0.1:$CDP_PORT" "http://127.0.0.1:$VIEWER_PORT" before "$OUTPUT_DIR"
  verify_browser_agent_bridge before
docker compose --project-name "$PROJECT" --env-file "$ENV_FILE" -f "$ROOT_DIR/runtime/docker-compose.yml" -f "$OVERRIDE_FILE" exec -T viewer sh -lc 'cat /home/neko/.config/chromium/acceptance-requests.jsonl' >"$OUTPUT_DIR/before-requests.jsonl"
BEFORE_VIEWER="$(docker compose --project-name "$PROJECT" --env-file "$ENV_FILE" -f "$ROOT_DIR/runtime/docker-compose.yml" -f "$OVERRIDE_FILE" ps -q viewer)"
BEFORE_CONTROL="$(docker compose --project-name "$PROJECT" --env-file "$ENV_FILE" -f "$ROOT_DIR/runtime/docker-compose.yml" -f "$OVERRIDE_FILE" ps -q control)"
  docker compose --project-name "$PROJECT" --env-file "$ENV_FILE" -f "$ROOT_DIR/runtime/docker-compose.yml" -f "$OVERRIDE_FILE" down
  docker compose --project-name "$PROJECT" --env-file "$ENV_FILE" -f "$ROOT_DIR/runtime/docker-compose.yml" -f "$OVERRIDE_FILE" up --detach --build --wait --wait-timeout 120

  record_browser_agent_installation after 0.1.1
  wait_for_cdp after
  record_chromium_argv after
  node "$TEST_DIR/persistence.mjs" "http://127.0.0.1:$CDP_PORT" "http://127.0.0.1:$VIEWER_PORT" after "$OUTPUT_DIR"
  verify_browser_agent_bridge after
AFTER_VIEWER="$(docker compose --project-name "$PROJECT" --env-file "$ENV_FILE" -f "$ROOT_DIR/runtime/docker-compose.yml" -f "$OVERRIDE_FILE" ps -q viewer)"
AFTER_CONTROL="$(docker compose --project-name "$PROJECT" --env-file "$ENV_FILE" -f "$ROOT_DIR/runtime/docker-compose.yml" -f "$OVERRIDE_FILE" ps -q control)"
[[ "$BEFORE_VIEWER" != "$AFTER_VIEWER" && "$BEFORE_CONTROL" != "$AFTER_CONTROL" ]]
docker compose --project-name "$PROJECT" --env-file "$ENV_FILE" -f "$ROOT_DIR/runtime/docker-compose.yml" -f "$OVERRIDE_FILE" exec -T viewer sh -lc 'cat /home/neko/.config/chromium/acceptance-requests.jsonl' >"$OUTPUT_DIR/after-requests.jsonl"
  python3 "$TEST_DIR/validate-persistence.py" "$OUTPUT_DIR/before-requests.jsonl" "$OUTPUT_DIR/after-requests.jsonl" "$MARKER"

  printf 'before_viewer=%s\nafter_viewer=%s\n' "$BEFORE_VIEWER" "$AFTER_VIEWER"
  printf 'before_control=%s\nafter_control=%s\n' "$BEFORE_CONTROL" "$AFTER_CONTROL"
  docker compose --project-name "$PROJECT" --env-file "$ENV_FILE" -f "$ROOT_DIR/runtime/docker-compose.yml" -f "$OVERRIDE_FILE" ps
  docker compose --project-name "$PROJECT" --env-file "$ENV_FILE" -f "$ROOT_DIR/runtime/docker-compose.yml" -f "$OVERRIDE_FILE" exec -T viewer sh -lc 'tail -20 /home/neko/.config/chromium/acceptance-requests.jsonl'
  shopt -s nullglob
  image_files=("$OUTPUT_DIR"/*.png "$OUTPUT_DIR"/*.jpg)
  evidence_files=("$OUTPUT_DIR"/*-evidence.json)
  argv_files=("$OUTPUT_DIR"/*-chromium-argv.txt)
  cdp_files=("$OUTPUT_DIR"/*-cdp-version.json)
  installation_files=("$OUTPUT_DIR"/*-browser-agent-installation.txt)
  native_host_files=("$OUTPUT_DIR"/*-native-host-process.txt)
  native_bridge_files=("$OUTPUT_DIR"/*-native-bridge.json)
  update_files=("$OUTPUT_DIR"/*-browser-agent-update.xml)
  request_files=("$OUTPUT_DIR"/*-requests.jsonl)
  python3 "$TEST_DIR/audit-screenshots.py" "${image_files[@]}"
  shasum -a 256 "${image_files[@]}" "${evidence_files[@]}" "${argv_files[@]}" "${cdp_files[@]}" "${installation_files[@]}" \
    "${native_host_files[@]}" "${native_bridge_files[@]}" "${update_files[@]}" "${request_files[@]}"
} >>"$TRANSCRIPT" 2>&1

printf 'acceptance passed; evidence: %s\n' "$OUTPUT_DIR"
