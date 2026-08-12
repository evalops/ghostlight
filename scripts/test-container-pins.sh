#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

bash "$SCRIPT_DIR/check-container-pins.sh"
while IFS= read -r -d '' dockerfile; do
  while read -r keyword image _; do
    [[ "${keyword^^}" == FROM ]] || continue
    [[ "$image" == scratch ]] && continue
    if [[ ! "$image" =~ @sha256:[0-9a-f]{64}$ ]]; then
      printf '%s: mutable Dockerfile base found: %s\n' "${dockerfile#"$REPO_ROOT/"}" "$image" >&2
      exit 1
    fi
  done < <(grep -Ei '^[[:space:]]*FROM[[:space:]]+' "$dockerfile" || true)
done < <(find "$REPO_ROOT" -type f -name 'Dockerfile*' -not -path "$REPO_ROOT/.git/*" -print0)

# Without rg the checker must fail closed instead of passing vacuously.
fake_bin="$(mktemp -d)"
trap 'rm -rf "$fake_bin"' EXIT
for command in bash dirname find grep sed awk; do
  ln -s "$(command -v "$command")" "$fake_bin/$command"
done
if PATH="$fake_bin" bash "$SCRIPT_DIR/check-container-pins.sh" >/dev/null 2>&1; then
  printf 'check-container-pins.sh passed without rg; the pin gate must fail closed\n' >&2
  exit 1
fi
printf 'container pin tests passed\n'
