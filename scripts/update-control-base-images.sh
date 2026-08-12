#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'usage: %s [--root repository-root]\n' "$0" >&2
  exit 2
}

repo_root=''
while (( $# > 0 )); do
  case "$1" in
    --root)
      (( $# >= 2 )) || usage
      repo_root=$2
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done

if [[ -z "$repo_root" ]]; then
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null)
fi
[[ -d "$repo_root" ]] || {
  printf 'repository root is not a directory: %s\n' "$repo_root" >&2
  exit 2
}
repo_root=$(cd -- "$repo_root" && pwd)
dockerfile="$repo_root/control/Dockerfile"
[[ -f "$dockerfile" ]] || {
  printf 'required Dockerfile is missing: control/Dockerfile\n' >&2
  exit 1
}

resolve_digest() {
  local candidate=$1
  local override=$2
  local manifest
  local digest

  if [[ -n "$override" ]]; then
    digest=$override
  else
    command -v docker >/dev/null 2>&1 || {
      printf 'docker is required to resolve %s\n' "$candidate" >&2
      exit 1
    }
    command -v jq >/dev/null 2>&1 || {
      printf 'jq is required to resolve %s\n' "$candidate" >&2
      exit 1
    }
    manifest=$(docker buildx imagetools inspect "$candidate" --format '{{json .Manifest}}')
    digest=$(jq -r '.digest // .Digest // empty' <<<"$manifest")
  fi

  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || {
    printf 'registry did not return a canonical digest for %s\n' "$candidate" >&2
    exit 1
  }
  printf '%s\n' "$digest"
}

go_candidate=golang:1.25.12-alpine
alpine_candidate=alpine:3.22
go_digest=$(resolve_digest "$go_candidate" "${GHOSTLIGHT_GO_BASE_RESOLVED_DIGEST:-}")
alpine_digest=$(resolve_digest "$alpine_candidate" "${GHOSTLIGHT_ALPINE_BASE_RESOLVED_DIGEST:-}")
go_new="$go_candidate@$go_digest"
alpine_new="$alpine_candidate@$alpine_digest"

go_current=$(awk '$1 == "FROM" && $2 ~ /^golang:/ { print $2; exit }' "$dockerfile")
alpine_current=$(awk '$1 == "FROM" && $2 ~ /^alpine:/ { print $2; exit }' "$dockerfile")
[[ "$go_current" =~ ^golang:1\.25\.12-alpine@sha256:[0-9a-f]{64}$ ]] || {
  printf 'unexpected Go build base reference: %s\n' "$go_current" >&2
  exit 1
}
[[ "$alpine_current" =~ ^alpine:3\.22@sha256:[0-9a-f]{64}$ ]] || {
  printf 'unexpected Alpine runtime base reference: %s\n' "$alpine_current" >&2
  exit 1
}

if [[ "$go_current" != "$go_new" || "$alpine_current" != "$alpine_new" ]]; then
  GO_CURRENT="$go_current" GO_NEW="$go_new" ALPINE_CURRENT="$alpine_current" ALPINE_NEW="$alpine_new" \
    perl -0pi -e 's/\Q$ENV{GO_CURRENT}\E/$ENV{GO_NEW}/g; s/\Q$ENV{ALPINE_CURRENT}\E/$ENV{ALPINE_NEW}/g' "$dockerfile"
fi

grep -Fqx -- "FROM $go_new AS build" "$dockerfile" || {
  printf 'failed to apply Go build base digest\n' >&2
  exit 1
}
grep -Fqx -- "FROM $alpine_new" "$dockerfile" || {
  printf 'failed to apply Alpine runtime base digest\n' >&2
  exit 1
}
printf 'control bases resolved to %s and %s\n' "$go_new" "$alpine_new"
