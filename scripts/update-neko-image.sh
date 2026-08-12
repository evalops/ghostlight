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
[[ "$new_image" =~ ^ghcr\.io/(m1k1o/neko/chromium|evalops/ghostlight-viewer)@sha256:[0-9a-f]{64}$ ]] || {
  printf 'candidate is not a canonical Neko Chromium digest pin: %s\n' "$new_image" >&2
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

env_file="$repo_root/runtime/.env.example"
files=(
  "$env_file"
  "$repo_root/runtime/docker-compose.yml"
  "$repo_root/runtime/tests/test_runtime.sh"
)
for file in "${files[@]}"; do
  [[ -f "$file" ]] || {
    printf 'required Neko pin file is missing: %s\n' "${file#"$repo_root/"}" >&2
    exit 1
  }
done

current_image=$(awk -F= '$1 == "NEKO_IMAGE" { sub(/^[^=]*=/, ""); print; exit }' "$env_file")
[[ "$current_image" =~ ^ghcr\.io/(m1k1o/neko/chromium|evalops/ghostlight-viewer)@sha256:[0-9a-f]{64}$ ]] || {
  printf 'current NEKO_IMAGE is not a canonical digest pin: %s\n' "$current_image" >&2
  exit 1
}

if (( check_only == 1 )); then
  for file in "${files[@]}"; do
    grep -Fq -- "$new_image" "$file" || {
      printf '%s does not contain candidate pin %s\n' "${file#"$repo_root/"}" "$new_image" >&2
      exit 1
    }
  done
  exit 0
fi

if [[ "$current_image" == "$new_image" ]]; then
  "$0" --check --root "$repo_root" "$new_image"
  printf 'Neko Chromium already uses %s\n' "$new_image"
  exit 0
fi

for file in "${files[@]}"; do
  grep -Fq -- "$current_image" "$file" || {
    printf '%s does not contain current pin %s\n' "${file#"$repo_root/"}" "$current_image" >&2
    exit 1
  }
done

for file in "${files[@]}"; do
  OLD_IMAGE="$current_image" NEW_IMAGE="$new_image" perl -0pi -e 's/\Q$ENV{OLD_IMAGE}\E/$ENV{NEW_IMAGE}/g' "$file"
done

"$0" --check --root "$repo_root" "$new_image"
printf 'updated Neko Chromium from %s to %s\n' "$current_image" "$new_image"
