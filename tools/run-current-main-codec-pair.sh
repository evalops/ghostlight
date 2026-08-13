#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_ROOT="${GHOSTLIGHT_CODEC_PAIR_OUTPUT_DIR:-$ROOT_DIR/output/codec-pair-$(date -u +%Y%m%dT%H%M%SZ)}"
REMOTE="${GHOSTLIGHT_PERFORMANCE_REMOTE_HOST:-developer@192.168.4.113}"
REMOTE_ADDRESS="${GHOSTLIGHT_PERFORMANCE_REMOTE_ADDRESS:-192.168.4.113}"
MAC_ADDRESS="${GHOSTLIGHT_PERFORMANCE_MAC_ADDRESS:-192.168.4.103}"
BASE_PORT="${GHOSTLIGHT_PERFORMANCE_PORT_BASE:-41000}"
SOURCE_SHA="$(git -C "$ROOT_DIR" rev-parse HEAD)"
IMAGE="$(awk -F= '$1 == "NEKO_IMAGE" {print $2}' "$ROOT_DIR/runtime/.env.example")"
PASSWORD="${GHOSTLIGHT_PERFORMANCE_NEKO_PASSWORD:-ghostlight-performance-user}"
JSON_ONLY=false
[[ "${1:-}" != "--json" ]] || JSON_ONLY=true

[[ -n "$IMAGE" && "$IMAGE" == *@sha256:* ]] || { printf 'current runtime image must be digest pinned\n' >&2; exit 1; }
[[ -z "$(git -C "$ROOT_DIR" status --porcelain --untracked-files=all)" ]] || { printf 'codec pair requires a clean exact-source tree\n' >&2; exit 1; }
[[ "$SOURCE_SHA" == "$(git -C "$ROOT_DIR" rev-parse github/main)" ]] || { printf 'codec pair source must equal github/main\n' >&2; exit 1; }
[[ "$MAC_ADDRESS" == "$(ipconfig getifaddr en0)" ]] || { printf 'Mac source address must match en0\n' >&2; exit 1; }
mkdir -p "$OUTPUT_ROOT"
chmod 700 "$OUTPUT_ROOT"

macos/package-app.sh >/dev/null

FIREWALL_BEFORE="$OUTPUT_ROOT/firewall-before.txt"
FIREWALL_AFTER="$OUTPUT_ROOT/firewall-after.txt"
RUN_STATUS_FILE="$OUTPUT_ROOT/run-exit-statuses.tsv"
ssh -o BatchMode=yes "$REMOTE" 'sudo -n ufw status numbered' >"$FIREWALL_BEFORE"
: >"$RUN_STATUS_FILE"
chmod 600 "$RUN_STATUS_FILE"
RULES=()
cleanup_pair() {
  for rule in "${RULES[@]}"; do
    ssh -o BatchMode=yes "$REMOTE" "sudo -n ufw --force delete $rule" >/dev/null 2>&1 || true
  done
  ssh -o BatchMode=yes "$REMOTE" 'sudo -n ufw status numbered' >"$FIREWALL_AFTER" 2>&1 || true
}
trap cleanup_pair EXIT

add_rule() {
  local rule="$1"
  ssh -o BatchMode=yes "$REMOTE" "sudo -n ufw insert 1 $rule" >/dev/null
  RULES+=("$rule")
}

run_one() {
  local pair="$1" codec="$2" port="$3"
  local output="$OUTPUT_ROOT/pair-$pair/$codec"
  mkdir -p "$output"
  GHOSTLIGHT_PERFORMANCE_IMAGE="$IMAGE" \
  GHOSTLIGHT_PERFORMANCE_REMOTE_HOST="$REMOTE" \
  GHOSTLIGHT_PERFORMANCE_REMOTE_ADDRESS="$REMOTE_ADDRESS" \
  GHOSTLIGHT_PERFORMANCE_BIND_ADDRESS="$REMOTE_ADDRESS" \
  GHOSTLIGHT_PERFORMANCE_CLIENT_ADDRESS="$REMOTE_ADDRESS" \
  GHOSTLIGHT_PERFORMANCE_ICE_ADDRESS="$REMOTE_ADDRESS" \
  GHOSTLIGHT_PERFORMANCE_SSH_TUNNEL=false \
  GHOSTLIGHT_PERFORMANCE_PORT_BASE="$port" \
  GHOSTLIGHT_PERFORMANCE_TARGET_FPS=25 \
  GHOSTLIGHT_PERFORMANCE_WIDTH=1920 \
  GHOSTLIGHT_PERFORMANCE_HEIGHT=1080 \
  GHOSTLIGHT_PERFORMANCE_BITRATE_KBPS=3072 \
  GHOSTLIGHT_PERFORMANCE_CPU_USED=4 \
  GHOSTLIGHT_PERFORMANCE_USE_DAMAGE=false \
  GHOSTLIGHT_PERFORMANCE_CODEC="$codec" \
  GHOSTLIGHT_PERFORMANCE_PHASE_SECONDS="${GHOSTLIGHT_PERFORMANCE_PHASE_SECONDS:-30}" \
  GHOSTLIGHT_PERFORMANCE_WARMUP_SECONDS="${GHOSTLIGHT_PERFORMANCE_WARMUP_SECONDS:-10}" \
  GHOSTLIGHT_PERFORMANCE_NEKO_PASSWORD="$PASSWORD" \
  GHOSTLIGHT_PERFORMANCE_OUTPUT_DIR="$output" \
  GHOSTLIGHT_PERFORMANCE_RUN_ID="pair-$pair-$codec-$SOURCE_SHA" \
  GHOSTLIGHT_PERFORMANCE_NATIVE_OBSERVER_COMMAND="bash tools/run-native-performance-observer.sh" \
  node "$ROOT_DIR/tools/measure-streaming-performance.mjs" >"$output/harness.stdout" 2>"$output/harness.stderr"
}

run_recorded() {
  local pair="$1" codec="$2" port="$3" status
  if run_one "$pair" "$codec" "$port"; then
    status=0
  else
    status=$?
  fi
  printf 'pair-%s\t%s\t%s\n' "$pair" "$codec" "$status" >>"$RUN_STATUS_FILE"
}

for offset in 0 10 20 30 40 50; do
  viewer_port=$((BASE_PORT + offset))
  webrtc_port=$((viewer_port + 1))
  add_rule "allow in on eth0 proto tcp from $MAC_ADDRESS to any port $viewer_port comment ghostlight-codec-pair"
  add_rule "allow in on eth0 proto udp from $MAC_ADDRESS to any port $webrtc_port comment ghostlight-codec-pair"
done

run_recorded 1 vp8 "$BASE_PORT"
run_recorded 1 h264 "$((BASE_PORT + 10))"
run_recorded 2 h264 "$((BASE_PORT + 20))"
run_recorded 2 vp8 "$((BASE_PORT + 30))"
run_recorded 3 vp8 "$((BASE_PORT + 40))"
run_recorded 3 h264 "$((BASE_PORT + 50))"

set +e
node "$ROOT_DIR/tools/evaluate-codec-pair.mjs" "$OUTPUT_ROOT" "$OUTPUT_ROOT/result.json"
evaluation_status=$?
set -e
cleanup_pair
trap - EXIT

if rg -q 'ghostlight-codec-pair' "$FIREWALL_AFTER"; then
  printf 'temporary firewall rule cleanup failed\n' >&2
  exit 1
fi
if $JSON_ONLY; then
  cat "$OUTPUT_ROOT/result.json"
else
  printf 'codec pair receipt: %s\n' "$OUTPUT_ROOT/result.json"
fi
exit "$evaluation_status"
