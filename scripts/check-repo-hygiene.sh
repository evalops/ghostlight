#!/usr/bin/env bash
set -euo pipefail

if (( $# > 1 )); then
  printf 'usage: %s [repository-root]\n' "$0" >&2
  exit 2
fi

if (( $# == 1 )); then
  repo_root=$1
else
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null)
fi

if [[ ! -d "$repo_root" ]]; then
  printf 'repository root is not a directory: %s\n' "$repo_root" >&2
  exit 2
fi
repo_root=$(cd -- "$repo_root" && pwd)

failures=0
license_file="$repo_root/LICENSE"
notices_file="$repo_root/THIRD_PARTY_NOTICES.md"

if [[ ! -s "$license_file" ]]; then
  printf 'LICENSE is missing or empty\n' >&2
  failures=$((failures + 1))
else
  if ! grep -Fq -- 'Apache License' "$license_file"; then
    printf 'LICENSE does not identify the Apache License\n' >&2
    failures=$((failures + 1))
  fi
  if ! grep -Fq -- 'Version 2.0' "$license_file"; then
    printf 'LICENSE does not identify Apache License 2.0\n' >&2
    failures=$((failures + 1))
  fi
fi

if [[ ! -s "$notices_file" ]]; then
  printf 'THIRD_PARTY_NOTICES.md is missing or empty\n' >&2
  failures=$((failures + 1))
else
  if ! grep -Fqx -- '# Third-Party Notices' "$notices_file"; then
    printf 'THIRD_PARTY_NOTICES.md has no required title\n' >&2
    failures=$((failures + 1))
  fi
  if ! grep -Fqx -- '## Verification queue' "$notices_file"; then
    printf 'THIRD_PARTY_NOTICES.md has no verification queue\n' >&2
    failures=$((failures + 1))
  fi
  if ! awk -F'|' '
    BEGIN { invalid = 0; rows = 0 }
    /^\|/ && $0 !~ /^\|[[:space:]]*-/ && $0 !~ /^\|[[:space:]]*Dependency[[:space:]]*\|/ {
      rows++
      dependency = $2
      license = $4
      source = $5
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", dependency)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", license)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", source)
      if (dependency == "" || license == "" || source !~ /https:\/\/[[:alnum:]]/) {
        printf "dependency row %d needs a name, license, and canonical HTTPS source\n", NR
        invalid = 1
      }
    }
    END {
      if (rows == 0) {
        print "THIRD_PARTY_NOTICES.md has no dependency rows"
        invalid = 1
      }
      exit invalid
    }
  ' "$notices_file"; then
    failures=$((failures + 1))
  fi
fi

placeholder_pattern='(^|[^[:alnum:]_])(TODO|FIXME|TBD|PLACEHOLDER|LOREM[[:space:]]+IPSUM)($|[^[:alnum:]_])'
while IFS= read -r -d '' markdown_file; do
  if grep -nE '[[:blank:]]$' "$markdown_file"; then
    printf '%s contains trailing whitespace\n' "${markdown_file#"$repo_root/"}" >&2
    failures=$((failures + 1))
  fi
  if grep -nE '^#{1,6}[[:space:]]*$' "$markdown_file"; then
    printf '%s contains an empty heading\n' "${markdown_file#"$repo_root/"}" >&2
    failures=$((failures + 1))
  fi
  if grep -Ein "$placeholder_pattern" "$markdown_file"; then
    printf '%s contains an unresolved placeholder\n' "${markdown_file#"$repo_root/"}" >&2
    failures=$((failures + 1))
  fi
done < <(find "$repo_root" -type f -name '*.md' -not -path "$repo_root/.git/*" -print0)

if (( failures > 0 )); then
  printf 'Repository license and prose hygiene check failed with %d issue(s).\n' "$failures" >&2
  exit 1
fi

printf 'Repository license and prose hygiene checks passed.\n'
