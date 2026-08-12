#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

failures=0

while IFS= read -r -d '' dockerfile; do
  while IFS= read -r line; do
    case "$line" in
      FROM\ *\ AS\ *|FROM\ *)
        image="${line#FROM }"
        image="${image%% AS *}"
        if [[ ! "$image" =~ @sha256:[0-9a-f]{64}$ ]]; then
          printf '%s: unpinned base image: %s\n' "${dockerfile#"$REPO_ROOT/"}" "$image" >&2
          failures=$((failures + 1))
        fi
        ;;
    esac
  done <"$dockerfile"
done < <(find "$REPO_ROOT" -type f -name 'Dockerfile*' -not -path "$REPO_ROOT/.git/*" -print0)

while IFS= read -r line; do
  image="${line#*image: }"
  image="${image%\"}"
  image="${image#\"}"
  if [[ ! "$image" =~ @sha256:[0-9a-f]{64} ]]; then
    printf 'Compose image is not digest-pinned: %s\n' "$image" >&2
    failures=$((failures + 1))
  fi
done < <(rg -n '^[[:space:]]*image:' "$REPO_ROOT" -g 'compose*.yml' -g 'compose*.yaml' -g 'docker-compose*.yml' -g 'docker-compose*.yaml' | sed -E 's/^[^:]+:[0-9]+://')

while IFS= read -r line; do
  ref="${line##*@}"
  if [[ ! "$ref" =~ ^[0-9a-f]{40}$ ]]; then
    printf 'GitHub Action is not pinned to a full commit: %s\n' "$line" >&2
    failures=$((failures + 1))
  fi
done < <(rg -n '^[[:space:]]*uses:[[:space:]]*[^[:space:]]+@' "$REPO_ROOT/.github/workflows" -g '*.yml' -g '*.yaml' | sed -E 's/^[^:]+:[0-9]+:[[:space:]]*uses:[[:space:]]*[^@]+@//')

if (( failures > 0 )); then
  printf 'container and workflow pin check failed with %d issue(s)\n' "$failures" >&2
  exit 1
fi

printf 'container and workflow pin checks passed\n'
