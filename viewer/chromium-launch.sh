#!/bin/sh

set -eu

extension_id=okabifedphcnokaehflbkmpfphleoaha
expected_version="$(cat /opt/ghostlight/browser-agent.version)"
profile_root=/home/neko/.config/chromium
extension_root="$profile_root/Default/Extensions/$extension_id"

chromium_running=0
for cmdline in /proc/[0-9]*/cmdline; do
  [ -r "$cmdline" ] || continue
  if [ "$(tr '\000' '\n' <"$cmdline" | sed -n '1p')" = /usr/lib/chromium/chromium ]; then
    chromium_running=1
    break
  fi
done
if [ "$chromium_running" -eq 0 ]; then
  rm -f -- "$profile_root/SingletonCookie" "$profile_root/SingletonLock" "$profile_root/SingletonSocket"
fi

migration_needed=0
if ! find "$extension_root" -mindepth 1 -maxdepth 1 -type d -name "${expected_version}_*" -print -quit 2>/dev/null | grep -q .; then
  migration_needed=1
  if [ -d "$extension_root" ]; then
    find "$extension_root" -mindepth 1 -maxdepth 1 -type d ! -name "${expected_version}_*" -exec rm -rf -- {} +
  fi
fi

set -- /usr/bin/chromium "$@"
if [ "$migration_needed" -eq 1 ]; then
  set -- "$@" --extensions-update-frequency=30
  browser_pid=$$
  (
    attempt=0
    while [ "$attempt" -lt 90 ]; do
      if find "$extension_root" -mindepth 2 -maxdepth 2 -type f \
        -path "*/${expected_version}_*/manifest.json" -print -quit 2>/dev/null | grep -q .; then
        sleep 1
        kill -INT "$browser_pid"
        exit 0
      fi
      attempt=$((attempt + 1))
      sleep 1
    done
  ) &
fi

exec "$@"
