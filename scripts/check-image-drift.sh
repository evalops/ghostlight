#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_DIR="$(cd -- "$SCRIPT_DIR/../runtime" && pwd)"
CONTROL_DIR="$(cd -- "$SCRIPT_DIR/../control" && pwd)"
neko_candidate="${GHOSTLIGHT_NEKO_CANDIDATE_IMAGE:-ghcr.io/m1k1o/neko/chromium:latest}"
go_candidate="${GHOSTLIGHT_GO_BASE_CANDIDATE:-golang:1.25.12-alpine}"
alpine_candidate="${GHOSTLIGHT_ALPINE_BASE_CANDIDATE:-alpine:3.22}"
neko_pinned="$(awk -F= '$1 == "NEKO_IMAGE" { sub(/^[^=]*=/, ""); print; exit }' "$RUNTIME_DIR/.env.example")"
go_pinned="$(awk '$1 == "FROM" && $2 ~ /golang/ { image = $2; sub(/^[^@]*@/, "", image); print image; exit }' "$CONTROL_DIR/Dockerfile")"
alpine_pinned="$(awk '$1 == "FROM" && $2 ~ /^alpine/ { image = $2; sub(/^[^@]*@/, "", image); print image; exit }' "$CONTROL_DIR/Dockerfile")"

command -v docker >/dev/null 2>&1 || { printf 'docker is required for image drift detection\n' >&2; exit 1; }

failures=0

check_candidate() {
  local label="$1"
  local candidate="$2"
  local pinned="$3"
  local candidate_digest

  candidate_digest="$(docker buildx imagetools inspect "$candidate" --format '{{.Manifest.Digest}}' 2>/dev/null || true)"
  if [[ ! "$candidate_digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    printf '%s: could not resolve candidate digest for %s\n' "$label" "$candidate" >&2
    failures=$((failures + 1))
    return
  fi
  if [[ "$pinned" == "$candidate_digest" || "$pinned" == *"@$candidate_digest" ]]; then
    printf '%s digest unchanged: %s\n' "$label" "$candidate_digest"
  else
    printf '%s digest drift detected: pinned=%s candidate=%s\n' "$label" "$pinned" "$candidate_digest"
    failures=$((failures + 10))
  fi
}

check_candidate "Neko" "$neko_candidate" "$neko_pinned"
check_candidate "Go build base" "$go_candidate" "$go_pinned"
check_candidate "Alpine runtime base" "$alpine_candidate" "$alpine_pinned"

if (( failures > 0 )); then
  exit 10
fi
