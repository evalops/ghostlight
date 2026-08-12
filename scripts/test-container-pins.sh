#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

bash "$SCRIPT_DIR/check-container-pins.sh"
while IFS= read -r -d '' dockerfile; do
  while read -r keyword image _; do
    [[ "$keyword" == FROM ]] || continue
    if [[ ! "$image" =~ @sha256:[0-9a-f]{64}$ ]]; then
      printf '%s: mutable Dockerfile base found: %s\n' "${dockerfile#"$REPO_ROOT/"}" "$image" >&2
      exit 1
    fi
  done < <(rg '^FROM[[:space:]]+' "$dockerfile" || true)
done < <(find "$REPO_ROOT" -type f -name 'Dockerfile*' -not -path "$REPO_ROOT/.git/*" -print0)
printf 'container pin tests passed\n'
