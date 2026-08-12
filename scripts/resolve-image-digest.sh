#!/usr/bin/env bash
set -euo pipefail

if (( $# != 1 )); then
  printf 'usage: %s ghcr.io/m1k1o/neko/chromium:<tag-or-digest>\n' "$0" >&2
  exit 2
fi

candidate=$1
if [[ "$candidate" =~ ^ghcr\.io/m1k1o/neko/chromium@sha256:[0-9a-f]{64}$ ]]; then
  printf '%s\n' "$candidate"
  exit 0
fi
if [[ ! "$candidate" =~ ^ghcr\.io/m1k1o/neko/chromium:[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; then
  printf 'candidate must be a tagged or digest-pinned Neko Chromium image: %s\n' "$candidate" >&2
  exit 2
fi

command -v docker >/dev/null 2>&1 || {
  printf 'docker is required to resolve an image digest\n' >&2
  exit 1
}
command -v jq >/dev/null 2>&1 || {
  printf 'jq is required to resolve an image digest\n' >&2
  exit 1
}

manifest=$(docker buildx imagetools inspect "$candidate" --format '{{json .Manifest}}')
digest=$(jq -r '.digest // .Digest // empty' <<<"$manifest")
if [[ ! "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
  printf 'registry did not return a canonical digest for %s\n' "$candidate" >&2
  exit 1
fi

printf 'ghcr.io/m1k1o/neko/chromium@%s\n' "$digest"
