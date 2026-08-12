#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
APP_DIR="$SCRIPT_DIR/.build/Ghostlight.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"

[[ "$APP_DIR" == "$SCRIPT_DIR/.build/Ghostlight.app" ]] || {
  printf 'refusing unexpected app path: %s\n' "$APP_DIR" >&2
  exit 1
}
[[ ! -L "$APP_DIR" ]] || {
  printf 'refusing to replace symlink: %s\n' "$APP_DIR" >&2
  exit 1
}

swift build --package-path "$SCRIPT_DIR" --configuration "$CONFIGURATION"
BIN_DIR="$(swift build --package-path "$SCRIPT_DIR" --configuration "$CONFIGURATION" --show-bin-path)"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
cp "$SCRIPT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$BIN_DIR/GhostlightApp" "$MACOS_DIR/GhostlightApp"

if command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - "$APP_DIR"
fi

printf '%s\n' "$APP_DIR"
