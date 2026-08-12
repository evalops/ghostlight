#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${GHOSTLIGHT_APP_PATH:-$ROOT_DIR/macos/.build/Ghostlight.app}"
CONTROL_URL="${GHOSTLIGHT_CONTROL_URL:-}"
OUTPUT_DIR="${GHOSTLIGHT_MACOS_ACCEPTANCE_OUTPUT_DIR:-$ROOT_DIR/output/macos-acceptance}"
BUNDLE_ID="org.evalops.Ghostlight"
PROCESS_NAME="GhostlightApp"
AUDIT_SCRIPT="$ROOT_DIR/tests/acceptance/audit-screenshots.py"

[[ "$(uname -s)" == Darwin ]] || { printf 'macOS is required\n' >&2; exit 1; }
[[ -n "$CONTROL_URL" ]] || { printf 'set GHOSTLIGHT_CONTROL_URL to a synthetic test control plane\n' >&2; exit 1; }
[[ -d "$APP_PATH" && ! -L "$APP_PATH" ]] || { printf 'expected app bundle at %s\n' "$APP_PATH" >&2; exit 1; }
for command in open osascript plutil shasum codesign python3; do
  command -v "$command" >/dev/null || { printf 'missing command: %s\n' "$command" >&2; exit 1; }
done

mkdir -p "$OUTPUT_DIR"
TRANSCRIPT="$OUTPUT_DIR/transcript.txt"
: >"$TRANSCRIPT"
CONTROL_ENDPOINT_SHA256="$(printf '%s' "$CONTROL_URL" | shasum -a 256 | awk '{print $1}')"
{
  printf 'captured_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'git_head=%s\napp_path=%s\ncontrol_endpoint_sha256=%s\n' "$(git -C "$ROOT_DIR" rev-parse HEAD)" "$APP_PATH" "$CONTROL_ENDPOINT_SHA256"
  printf 'bundle_id=%s\n' "$(plutil -extract CFBundleIdentifier raw -o - "$APP_PATH/Contents/Info.plist")"
  codesign --verify --deep --strict "$APP_PATH"
} >>"$TRANSCRIPT" 2>&1

wait_for_loaded() {
  local attempt dump
  for ((attempt = 1; attempt <= 30; attempt++)); do
    dump="$(osascript <<EOF 2>/dev/null || true
tell application "System Events"
  tell process "$PROCESS_NAME"
    return entire contents of window 1 as text
  end tell
end tell
EOF
)"
    if [[ "$dump" == *"Viewer loaded"* ]]; then
      printf '%s\n' "$dump"
      return 0
    fi
    sleep 1
  done
  return 1
}

# First launch obtains the URL from the explicitly scoped environment. The app
# itself persists it only after successful discovery. The second launch omits
# the environment, so reaching Viewer loaded proves automatic saved-URL reuse.
FIRST_PID=""
SECOND_PID=""
cleanup_relaunch() {
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  [[ -z "$FIRST_PID" ]] || kill "$FIRST_PID" 2>/dev/null || true
  [[ -z "$SECOND_PID" ]] || kill "$SECOND_PID" 2>/dev/null || true
}
trap cleanup_relaunch EXIT
osascript -e "tell application id \"$BUNDLE_ID\" to quit" 2>/dev/null || true
sleep 2
GHOSTLIGHT_CONTROL_URL="$CONTROL_URL" "$APP_PATH/Contents/MacOS/GhostlightApp" >>"$OUTPUT_DIR/first-launch-app.log" 2>&1 &
FIRST_PID=$!
FIRST_UI="$(wait_for_loaded)" || { printf 'first launch never reached Viewer loaded\n' >&2; exit 1; }
printf 'first_ui=%s\n' "$FIRST_UI" >>"$TRANSCRIPT"
screencapture -x "$OUTPUT_DIR/first-launch.png"
osascript -e "tell application id \"$BUNDLE_ID\" to quit"
wait "$FIRST_PID" 2>/dev/null || true
env -u GHOSTLIGHT_CONTROL_URL "$APP_PATH/Contents/MacOS/GhostlightApp" >>"$OUTPUT_DIR/relaunch-app.log" 2>&1 &
SECOND_PID=$!
[[ "$FIRST_PID" != "$SECOND_PID" ]] || { printf 'relaunch reused the first process unexpectedly\n' >&2; exit 1; }
SECOND_UI="$(wait_for_loaded)" || { printf 'relaunch never reached Viewer loaded without environment URL\n' >&2; exit 1; }
printf 'relaunch_ui=%s\n' "$SECOND_UI" >>"$TRANSCRIPT"
screencapture -x "$OUTPUT_DIR/relaunch.png"
osascript -e "tell application id \"$BUNDLE_ID\" to quit"
wait "$SECOND_PID" 2>/dev/null || true
python3 "$AUDIT_SCRIPT" "$OUTPUT_DIR/first-launch.png" "$OUTPUT_DIR/relaunch.png" >>"$TRANSCRIPT" 2>&1

{
  printf 'first_launch_sha256='; shasum -a 256 "$OUTPUT_DIR/first-launch.png" | awk '{print $1}'
  printf 'relaunch_sha256='; shasum -a 256 "$OUTPUT_DIR/relaunch.png" | awk '{print $1}'
  printf 'result=launched_with_environment_then_relaunched_from_saved_url\n'
  printf 'semantic_assertion=both launches exposed Viewer loaded through macOS Accessibility; second launch omitted GHOSTLIGHT_CONTROL_URL\n'
  printf 'visual_assertion=screenshots still require privacy and rendering review before publication\n'
} >>"$TRANSCRIPT"
printf 'macOS relaunch evidence captured for manual review: %s\n' "$OUTPUT_DIR"
