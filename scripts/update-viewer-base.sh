#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'usage: %s [--check] [--root repository-root] ghcr.io/m1k1o/neko/chromium@sha256:<digest>\n' "$0" >&2
  exit 2
}

check_only=0
repo_root=''
while (( $# > 0 )); do
  case "$1" in
    --check)
      check_only=1
      shift
      ;;
    --root)
      (( $# >= 2 )) || usage
      repo_root=$2
      shift 2
      ;;
    --*)
      usage
      ;;
    *)
      break
      ;;
  esac
done

(( $# == 1 )) || usage
new_image=$1
[[ "$new_image" =~ ^ghcr\.io/m1k1o/neko/chromium@sha256:[0-9a-f]{64}$ ]] || {
  printf 'candidate is not a canonical upstream Neko Chromium digest pin: %s\n' "$new_image" >&2
  exit 2
}

if [[ -z "$repo_root" ]]; then
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null)
fi
[[ -d "$repo_root" ]] || {
  printf 'repository root is not a directory: %s\n' "$repo_root" >&2
  exit 2
}
repo_root=$(cd -- "$repo_root" && pwd)

dockerfile="$repo_root/viewer/Dockerfile"
[[ -f "$dockerfile" ]] || {
  printf 'required viewer Dockerfile is missing: viewer/Dockerfile\n' >&2
  exit 1
}

current_image=$(awk '$1 == "FROM" && $2 ~ /^ghcr\.io\/m1k1o\/neko\/chromium@/ { print $2; exit }' "$dockerfile")
[[ "$current_image" =~ ^ghcr\.io/m1k1o/neko/chromium@sha256:[0-9a-f]{64}$ ]] || {
  printf 'viewer base is not a canonical upstream Neko Chromium digest pin: %s\n' "$current_image" >&2
  exit 1
}

if (( check_only == 1 )); then
  grep -Fq -- "FROM $new_image" "$dockerfile" || {
    printf 'viewer/Dockerfile does not contain candidate base pin %s\n' "$new_image" >&2
    exit 1
  }
  exit 0
fi

if [[ "$current_image" == "$new_image" ]]; then
  "$0" --check --root "$repo_root" "$new_image"
  printf 'hardened viewer already builds from %s\n' "$new_image"
  exit 0
fi

OLD_IMAGE="$current_image" NEW_IMAGE="$new_image" perl -0pi -e 's/\Q$ENV{OLD_IMAGE}\E/$ENV{NEW_IMAGE}/g' "$dockerfile"

"$0" --check --root "$repo_root" "$new_image"
printf 'updated hardened viewer base from %s to %s\n' "$current_image" "$new_image"
