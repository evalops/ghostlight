#!/bin/sh

set -eu

extension_id=okabifedphcnokaehflbkmpfphleoaha
expected_version="$(cat /opt/ghostlight/browser-agent.version)"
extension_root="/home/neko/.config/chromium/Default/Extensions/$extension_id"

set -- /usr/bin/chromium "$@"
if ! find "$extension_root" -mindepth 1 -maxdepth 1 -type d -name "${expected_version}_*" -print -quit 2>/dev/null | grep -q .; then
  if [ -d "$extension_root" ]; then
    find "$extension_root" -mindepth 1 -maxdepth 1 -type d ! -name "${expected_version}_*" -exec rm -rf -- {} +
  fi
  set -- "$@" --extensions-update-frequency=30
fi

exec "$@"
