#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

if ! command -v rg >/dev/null 2>&1; then
  printf 'ripgrep (rg) is required to audit container and workflow pins.\n' >&2
  exit 1
fi

failures=0
checked_references=0

dockerfile_count=0
while IFS= read -r -d '' dockerfile; do
  dockerfile_count=$((dockerfile_count + 1))
  while IFS= read -r from_line; do
    image=$(awk '{ print $2 }' <<<"$from_line")
    if [[ "$image" == scratch ]]; then
      continue
    fi
    checked_references=$((checked_references + 1))
    if [[ ! "$image" =~ @sha256:[0-9a-f]{64}$ ]]; then
      printf '%s: unpinned base image: %s\n' "${dockerfile#"$REPO_ROOT/"}" "$image" >&2
      failures=$((failures + 1))
    fi
  done < <(grep -Ei '^[[:space:]]*FROM[[:space:]]+' "$dockerfile" || true)
done < <(find "$REPO_ROOT" -type f -name 'Dockerfile*' -not -path "$REPO_ROOT/.git/*" -print0)

if (( dockerfile_count == 0 )); then
  printf 'no Dockerfiles found to validate\n' >&2
  failures=$((failures + 1))
fi

while IFS= read -r line; do
  checked_references=$((checked_references + 1))
  image=$(sed -E 's/^[[:space:]]*image[[:space:]]*:[[:space:]]*//' <<<"$line")
  image="${image%\"}"
  image="${image#\"}"
  if [[ ! "$image" =~ @sha256:[0-9a-f]{64} ]]; then
    printf 'Compose image is not digest-pinned: %s\n' "$image" >&2
    failures=$((failures + 1))
  fi
done < <(rg -n '^[[:space:]]*image[[:space:]]*:' "$REPO_ROOT" -g 'compose*.yml' -g 'compose*.yaml' -g 'docker-compose*.yml' -g 'docker-compose*.yaml' | sed -E 's/^[^:]+:[0-9]+://')

while IFS= read -r line; do
  checked_references=$((checked_references + 1))
  ref="${line##*@}"
  if [[ ! "$ref" =~ ^[0-9a-f]{40}$ ]]; then
    printf 'GitHub Action is not pinned to a full commit: %s\n' "$line" >&2
    failures=$((failures + 1))
  fi
done < <(rg -n '^[[:space:]]*(-[[:space:]]*)?uses[[:space:]]*:[[:space:]]*[^[:space:]]+@' "$REPO_ROOT/.github/workflows" -g '*.yml' -g '*.yaml' | sed -E 's/^[^:]+:[0-9]+:[[:space:]]*(-[[:space:]]*)?uses[[:space:]]*:[[:space:]]*[^@]+@//')

if (( checked_references == 0 )); then
  printf 'no image or action references were checked; refusing to pass vacuously\n' >&2
  failures=$((failures + 1))
fi

if (( failures > 0 )); then
  printf 'container and workflow pin check failed with %d issue(s)\n' "$failures" >&2
  exit 1
fi

printf 'container and workflow pin checks passed\n'
