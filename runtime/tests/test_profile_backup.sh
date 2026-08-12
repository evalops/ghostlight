#!/usr/bin/env bash

set -euo pipefail

RUNTIME_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_SCRIPT="$RUNTIME_DIR/bin/profile-backup.sh"
SCRATCH_DIR="$(mktemp -d)"
trap 'rm -rf "$SCRATCH_DIR"' EXIT

fail() {
  printf 'profile backup test failed: %s\n' "$*" >&2
  exit 1
}

expect_failure() {
  local label="$1"
  shift
  if "$@" >"$SCRATCH_DIR/output" 2>&1; then
    fail "$label unexpectedly passed"
  fi
}

stat_mode() {
  if stat -c '%a' "$1" >/dev/null 2>&1; then
    stat -c '%a' "$1"
  else
    stat -f '%Lp' "$1"
  fi
}

write_checksum() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}' >"$path.sha256"
  else
    shasum -a 256 "$path" | awk '{print $1}' >"$path.sha256"
  fi
  chmod 600 "$path.sha256"
}

fixture_root="$SCRATCH_DIR"
if [[ "$(uname -s)" == Darwin && -L /var ]]; then
  canonical_scratch="$(cd -P -- "$SCRATCH_DIR" && pwd)"
  case "$canonical_scratch" in
    /private/var/*)
      fixture_root="/var/${canonical_scratch#/private/var/}"
      ;;
    *)
      fail "macOS regression fixture must resolve the /var platform alias"
      ;;
  esac
fi

source="$fixture_root/source"
archive="$fixture_root/profile.tar.gz"
mkdir -m 700 "$source"
mkdir -m 700 "$source/Default" "$source/Default/Sessions"
printf 'synthetic-cookie=cookie-value\n' >"$source/Default/Cookies"
printf 'synthetic-tab=state-a\n' >"$source/Default/Sessions/Tabs_1"
printf 'synthetic-local-storage=state-a\n' >"$source/Default/Local State"
chmod 600 "$source/Default/Cookies"
chmod 640 "$source/Default/Sessions/Tabs_1"
chmod 600 "$source/Default/Local State"
ln -s "$SCRATCH_DIR/stale-singleton" "$source/SingletonSocket"

PROFILE_BACKUP_SKIP_COMPOSE=1 "$BACKUP_SCRIPT" backup "$source" "$archive"
[[ -f "$archive.sha256" ]] || fail "backup checksum is missing"
[[ "$(stat_mode "$archive")" == 600 ]] \
  || fail "backup archive must have mode 600"

printf 'synthetic-cookie=changed-after-backup\n' >"$source/Default/Cookies"
printf 'synthetic-tab=state-b\n' >"$source/Default/Sessions/Tabs_1"

destination="$SCRATCH_DIR/restored"
PROFILE_BACKUP_SKIP_COMPOSE=1 "$BACKUP_SCRIPT" restore "$archive" "$destination"
grep --fixed-strings 'synthetic-cookie=cookie-value' "$destination/Default/Cookies" >/dev/null \
  || fail "backup-time cookie content was not recovered"
grep --fixed-strings 'synthetic-tab=state-a' "$destination/Default/Sessions/Tabs_1" >/dev/null \
  || fail "backup-time tab content was not recovered"
grep --fixed-strings 'synthetic-local-storage=state-a' "$destination/Default/Local State" >/dev/null \
  || fail "local storage content was not recovered"
[[ ! -e "$destination/SingletonSocket" && ! -L "$destination/SingletonSocket" ]] \
  || fail "ephemeral Chromium singleton symlink must not be restored"
if stat -c '%a' "$destination/Default/Cookies" >/dev/null 2>&1; then
  cookie_mode="$(stat -c '%a' "$destination/Default/Cookies")"
  tab_mode="$(stat -c '%a' "$destination/Default/Sessions/Tabs_1")"
else
  cookie_mode="$(stat -f '%Lp' "$destination/Default/Cookies")"
  tab_mode="$(stat -f '%Lp' "$destination/Default/Sessions/Tabs_1")"
fi
[[ "$cookie_mode" == 600 ]] || fail "cookie permissions were not preserved"
[[ "$tab_mode" == 640 ]] || fail "tab permissions were not preserved"

expect_failure "existing destination" env PROFILE_BACKUP_SKIP_COMPOSE=1 "$BACKUP_SCRIPT" restore "$archive" "$destination"
printf 'corrupted\n' >"$archive.sha256"
expect_failure "checksum mismatch" env PROFILE_BACKUP_SKIP_COMPOSE=1 "$BACKUP_SCRIPT" restore "$archive" "$SCRATCH_DIR/checksum-failure"
write_checksum "$archive"

expect_failure "existing archive" env PROFILE_BACKUP_SKIP_COMPOSE=1 "$BACKUP_SCRIPT" backup "$source" "$archive"

ln -s "$source" "$SCRATCH_DIR/source-link"
expect_failure "source symlink" env PROFILE_BACKUP_SKIP_COMPOSE=1 "$BACKUP_SCRIPT" backup "$SCRATCH_DIR/source-link" "$SCRATCH_DIR/symlink.tar.gz"
ln -s "$archive" "$SCRATCH_DIR/archive-link"
expect_failure "archive symlink" env PROFILE_BACKUP_SKIP_COMPOSE=1 "$BACKUP_SCRIPT" restore "$SCRATCH_DIR/archive-link" "$SCRATCH_DIR/symlink-restore"

mkdir -m 700 "$source/nested"
ln -s "$source/Default/Cookies" "$source/nested/cookie-link"
expect_failure "nested source symlink" env PROFILE_BACKUP_SKIP_COMPOSE=1 "$BACKUP_SCRIPT" backup "$source" "$SCRATCH_DIR/nested-link.tar.gz"
rm "$source/nested/cookie-link"

mkdir -m 700 "$SCRATCH_DIR/real-parent"
ln -s "$SCRATCH_DIR/real-parent" "$SCRATCH_DIR/parent-link"
expect_failure "restore parent symlink" env PROFILE_BACKUP_SKIP_COMPOSE=1 "$BACKUP_SCRIPT" restore "$archive" "$SCRATCH_DIR/parent-link/restored"

mkdir -m 700 "$SCRATCH_DIR/archive-parent"
ln -s "$SCRATCH_DIR/archive-parent" "$SCRATCH_DIR/archive-parent-link"
expect_failure "archive parent symlink" env PROFILE_BACKUP_SKIP_COMPOSE=1 "$BACKUP_SCRIPT" restore "$SCRATCH_DIR/archive-parent-link/profile.tar.gz" "$SCRATCH_DIR/archive-parent-restore"

expect_failure "restore destination traversal" env PROFILE_BACKUP_SKIP_COMPOSE=1 "$BACKUP_SCRIPT" restore "$archive" "$SCRATCH_DIR/../traversal-destination"

evil="$SCRATCH_DIR/evil.tar.gz"
python3 - "$evil" <<'PY'
import sys
import tarfile
from pathlib import Path

archive = Path(sys.argv[1])
with tarfile.open(archive, "w:gz") as output:
    data = b"escape"
    info = tarfile.TarInfo("../escape")
    info.size = len(data)
    output.addfile(info, __import__("io").BytesIO(data))
PY
write_checksum "$evil"
expect_failure "archive traversal" env PROFILE_BACKUP_SKIP_COMPOSE=1 "$BACKUP_SCRIPT" restore "$evil" "$SCRATCH_DIR/traversal"
[[ ! -e "$SCRATCH_DIR/traversal" ]] || fail "traversal restore created a destination"

linked="$SCRATCH_DIR/linked.tar.gz"
python3 - "$linked" <<'PY'
import sys
import tarfile
from pathlib import Path

archive = Path(sys.argv[1])
with tarfile.open(archive, "w:gz") as output:
    root = tarfile.TarInfo("profile")
    root.type = tarfile.DIRTYPE
    output.addfile(root)
    link = tarfile.TarInfo("profile/Cookies")
    link.type = tarfile.SYMTYPE
    link.linkname = "../../escape"
    output.addfile(link)
PY
write_checksum "$linked"
expect_failure "archive symlink entry" env PROFILE_BACKUP_SKIP_COMPOSE=1 "$BACKUP_SCRIPT" restore "$linked" "$SCRATCH_DIR/linked-restore"
[[ ! -e "$SCRATCH_DIR/linked-restore" ]] || fail "link-bearing restore created a destination"

printf 'profile backup tests passed: synthetic cookies, tabs, local storage, permissions, checksum, path, and link safety verified\n'
