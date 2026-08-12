#!/usr/bin/env bash

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
COMPOSE_FILE="$RUNTIME_DIR/docker-compose.yml"
ENV_FILE="${GHOSTLIGHT_ENV_FILE:-$RUNTIME_DIR/.env}"

die() {
  printf 'profile-backup: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "missing '$1'"
}

sha256_digest() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

checksum_path() {
  printf '%s.sha256' "$1"
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

stat_mode() {
  if stat -c '%a' "$1" >/dev/null 2>&1; then
    stat -c '%a' "$1"
  else
    stat -f '%Lp' "$1"
  fi
}

stat_owner_uid() {
  if stat -c '%u' "$1" >/dev/null 2>&1; then
    stat -c '%u' "$1"
  else
    stat -f '%u' "$1"
  fi
}

is_macos_platform_alias() {
  local path="$1"

  [[ "$(uname -s)" == Darwin ]] || return 1
  case "$path" in
    /?*/*) return 1 ;;
    /?*) ;;
    *) return 1 ;;
  esac
  [[ -L "$path" && "$(stat_owner_uid "$path")" == 0 ]] || return 1
  [[ -e "$path" ]]
}

reject_symlink_components() {
  local path="$1"
  local current rest component

  case "$path" in
    /*)
      current="/"
      rest="${path#/}"
      ;;
    *)
      current="$(pwd)"
      rest="$path"
      ;;
  esac
  while [[ -n "$rest" ]]; do
    component="${rest%%/*}"
    if [[ "$rest" == */* ]]; then
      rest="${rest#*/}"
    else
      rest=""
    fi
    [[ "$component" == "." || "$component" == ".." ]] && continue
    current="${current%/}/$component"
    if [[ -L "$current" ]] && ! is_macos_platform_alias "$current"; then
      die "refusing symlink path component: $current"
    fi
  done
}

validate_source_tree() {
  local source="$1"

  python3 - "$source" <<'PY' || die "profile contains a symlink or unsupported file type"
import os
import stat
import sys

source = os.path.abspath(sys.argv[1])
for root, directories, files in os.walk(source, followlinks=False):
    for name in directories + files:
        path = os.path.join(root, name)
        if root == source and name.startswith("Singleton"):
            continue
        mode = os.lstat(path).st_mode
        if stat.S_ISLNK(mode) or not (stat.S_ISDIR(mode) or stat.S_ISREG(mode)):
            raise SystemExit(1)
PY
}

validate_archive_entries() {
  local archive="$1"

  python3 - "$archive" <<'PY' || die "archive contains an unsafe path, link, or file type"
import pathlib
import sys
import tarfile

roots = set()
seen = set()
root_directories = set()
with tarfile.open(sys.argv[1], "r:gz") as archive:
    for member in archive.getmembers():
        path = pathlib.PurePosixPath(member.name)
        if path.is_absolute() or not path.parts or any(part in ("", ".", "..") for part in path.parts):
            raise SystemExit(1)
        if not (member.isdir() or member.isfile()):
            raise SystemExit(1)
        if member.name in seen:
            raise SystemExit(1)
        seen.add(member.name)
        roots.add(path.parts[0])
        if len(path.parts) == 1 and member.isdir():
            root_directories.add(path.parts[0])
if len(roots) != 1 or roots != root_directories:
    raise SystemExit(1)
PY
}

verify_checksum() {
  local archive="$1"
  local checksum="$2"
  local expected actual extra

  read -r expected extra <"$checksum" || die "could not read archive checksum: $checksum"
  [[ -z "${extra:-}" ]] || die "archive checksum must contain exactly one digest: $checksum"
  [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || die "archive checksum is malformed: $checksum"
  actual="$(sha256_digest "$archive")"
  [[ "$actual" == "$expected" ]] || die "archive checksum mismatch: $archive"
}

viewer_project_name() {
  local repo_root project_name

  repo_root="$(cd -- "$RUNTIME_DIR/.." && pwd)"
  project_name="${COMPOSE_PROJECT_NAME:-$(env_value COMPOSE_PROJECT_NAME)}"
  printf '%s' "${project_name:-$(basename -- "$repo_root")}"
}

assert_viewer_stopped() {
  local project_name running

  [[ "${PROFILE_BACKUP_SKIP_COMPOSE:-0}" == 1 ]] && return 0
  project_name="$(viewer_project_name)"
  running="$(docker compose --project-name "$project_name" --env-file "$ENV_FILE" -f "$COMPOSE_FILE" \
    ps --quiet --status running viewer)"
  [[ -z "$running" ]] || die "viewer container is still running; refusing to archive a live Chromium profile"
}

quiesce_viewer() {
  local project_name

  [[ "${PROFILE_BACKUP_SKIP_COMPOSE:-0}" == 1 ]] && return 0
  [[ -f "$ENV_FILE" ]] || die "runtime/.env is required to quiesce the viewer"
  project_name="$(viewer_project_name)"
  docker compose --project-name "$project_name" --env-file "$ENV_FILE" -f "$COMPOSE_FILE" stop viewer >/dev/null
  assert_viewer_stopped
}

backup_profile() {
  local source="$1"
  local requested_archive="$2"
  local archive checksum archive_parent source_parent source_name lock_dir
  local temporary_archive temporary_checksum published_checksum digest

  [[ -d "$source" ]] || die "profile source is not a directory: $source"
  reject_symlink_components "$source"
  validate_source_tree "$source"

  reject_symlink_components "$requested_archive"
  archive_parent="$(cd -- "$(dirname -- "$requested_archive")" 2>/dev/null && pwd)" \
    || die "archive parent does not exist: $(dirname -- "$requested_archive")"
  reject_symlink_components "$archive_parent"
  archive="$archive_parent/$(basename -- "$requested_archive")"
  checksum="$(checksum_path "$archive")"
  [[ ! -e "$archive" && ! -L "$archive" ]] || die "refusing to overwrite existing archive: $archive"

  lock_dir="$archive.lock"
  mkdir -m 700 "$lock_dir" 2>/dev/null || die "backup target is already in use: $archive"
  [[ ! -e "$archive" && ! -L "$archive" ]] || die "refusing to overwrite archive created during backup: $archive"
  if [[ -e "$checksum" || -L "$checksum" ]]; then
    [[ -f "$checksum" && ! -L "$checksum" ]] \
      || die "refusing unsafe orphan checksum path: $checksum"
    rm -- "$checksum" || die "could not remove orphan checksum from an interrupted backup: $checksum"
  fi
  temporary_archive="$(mktemp "$archive_parent/.ghostlight-profile.XXXXXX.tar.gz")"
  temporary_checksum="$(mktemp "$archive_parent/.ghostlight-checksum.XXXXXX")"
  published_checksum=""
  cleanup_backup() {
    [[ -z "${temporary_archive:-}" ]] || rm -f -- "$temporary_archive"
    [[ -z "${temporary_checksum:-}" ]] || rm -f -- "$temporary_checksum"
    if [[ -n "${published_checksum:-}" && ! -e "$archive" && ! -L "$archive" ]]; then
      rm -f -- "$published_checksum"
    fi
    rmdir -- "$lock_dir" 2>/dev/null || true
  }
  trap cleanup_backup EXIT

  source_parent="$(cd -- "$(dirname -- "$source")" && pwd)"
  source_name="$(basename -- "$source")"
  quiesce_viewer

  # Re-check immediately before reading the profile: nothing else may have
  # restarted the viewer between the Compose stop and this archive read.
  assert_viewer_stopped

  COPYFILE_DISABLE=1 tar -czf "$temporary_archive" --numeric-owner \
    --exclude="$source_name/SingletonCookie" \
    --exclude="$source_name/SingletonLock" \
    --exclude="$source_name/SingletonSocket" \
    -C "$source_parent" "$source_name" || die "could not create profile archive"
  chmod 600 "$temporary_archive"
  validate_archive_entries "$temporary_archive"
  digest="$(sha256_digest "$temporary_archive")"
  printf '%s\n' "$digest" >"$temporary_checksum"
  chmod 600 "$temporary_checksum"
  verify_checksum "$temporary_archive" "$temporary_checksum"

  mv -n -- "$temporary_checksum" "$checksum"
  [[ ! -e "$temporary_checksum" ]] || die "refusing to overwrite checksum created during backup: $checksum"
  temporary_checksum=""
  published_checksum="$checksum"
  if [[ "${PROFILE_BACKUP_FAIL_AFTER_CHECKSUM_PUBLISH:-0}" == 1 ]]; then
    die "injected failure after checksum publication"
  fi
  mv -n -- "$temporary_archive" "$archive"
  [[ ! -e "$temporary_archive" ]] || die "refusing to overwrite archive created during backup: $archive"
  temporary_archive=""
  published_checksum=""
  trap - EXIT
  rmdir -- "$lock_dir"

  printf 'profile backup passed: archive=%s checksum=%s; viewer remains stopped\n' "$archive" "$checksum"
}

restore_profile() {
  local requested_archive="$1"
  local destination="$2"
  local archive archive_parent checksum parent temporary_destination

  reject_symlink_components "$requested_archive"
  archive_parent="$(cd -- "$(dirname -- "$requested_archive")" 2>/dev/null && pwd)" \
    || die "archive parent does not exist: $(dirname -- "$requested_archive")"
  reject_symlink_components "$archive_parent"
  archive="$archive_parent/$(basename -- "$requested_archive")"
  reject_symlink_components "$archive"
  [[ -f "$archive" ]] || die "archive does not exist: $archive"
  checksum="$(checksum_path "$archive")"
  reject_symlink_components "$checksum"
  [[ -f "$checksum" ]] || die "archive checksum file does not exist: $checksum"
  verify_checksum "$archive" "$checksum"
  validate_archive_entries "$archive"

  case "$destination" in
    /*) ;;
    *) die "restore destination must be an absolute path: $destination" ;;
  esac
  reject_symlink_components "$destination"
  case "/$destination/" in
    */../*|*/./*) die "restore destination contains a traversal segment: $destination" ;;
  esac
  [[ ! -e "$destination" && ! -L "$destination" ]] || die "refusing to overwrite existing restore destination: $destination"
  parent="$(dirname -- "$destination")"
  [[ -d "$parent" ]] || die "restore parent does not exist: $parent"
  reject_symlink_components "$parent"

  temporary_destination="$(mktemp -d "$parent/.ghostlight-restore.XXXXXX")"
  cleanup_restore() {
    if [[ -n "${temporary_destination:-}" && -d "$temporary_destination" && ! -L "$temporary_destination" ]]; then
      rm -rf -- "$temporary_destination"
    fi
  }
  trap cleanup_restore EXIT
  COPYFILE_DISABLE=1 tar -xpzf "$archive" --strip-components=1 -C "$temporary_destination" \
    || die "could not extract profile archive"
  chmod 700 "$temporary_destination"
  mv -n -- "$temporary_destination" "$destination"
  [[ ! -e "$temporary_destination" ]] || die "refusing to overwrite destination created during restore: $destination"
  temporary_destination=""
  trap - EXIT
  [[ "$(stat_mode "$destination")" == 700 ]] || die "restored profile directory does not have mode 700"
  printf 'profile restore passed: destination=%s\n' "$destination"
}

usage() {
  printf 'usage: %s backup <profile-directory> <archive.tar.gz>\n' "$0" >&2
  printf '       %s restore <archive.tar.gz> <absolute-new-destination>\n' "$0" >&2
  exit 2
}

require_command awk
require_command python3
require_command tar

case "${1:-}" in
  backup)
    [[ $# -eq 3 ]] || usage
    backup_profile "$2" "$3"
    ;;
  restore)
    [[ $# -eq 3 ]] || usage
    restore_profile "$2" "$3"
    ;;
  *)
    usage
    ;;
esac
