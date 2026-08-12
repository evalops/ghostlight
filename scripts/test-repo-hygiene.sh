#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)
checker="$script_dir/check-repo-hygiene.sh"
scratch_dir=$(mktemp -d)
trap 'rm -rf "$scratch_dir"' EXIT

if [[ ! -x "$checker" ]]; then
  printf 'checker is missing or not executable: %s\n' "$checker" >&2
  exit 1
fi

expect_success() {
  local label=$1
  local fixture=$2
  local output="$scratch_dir/output"

  if ! "$checker" "$fixture" >"$output" 2>&1; then
    printf 'FAIL: %s\n' "$label" >&2
    cat "$output" >&2
    return 1
  fi
  printf 'PASS: %s\n' "$label"
}

expect_failure() {
  local label=$1
  local fixture=$2
  local expected=$3
  local output="$scratch_dir/output"

  if "$checker" "$fixture" >"$output" 2>&1; then
    printf 'FAIL: %s unexpectedly passed\n' "$label" >&2
    return 1
  fi
  if ! grep -Fq -- "$expected" "$output"; then
    printf 'FAIL: %s did not report %s\n' "$label" "$expected" >&2
    cat "$output" >&2
    return 1
  fi
  printf 'PASS: %s\n' "$label"
}

expect_success_without_argument() {
  local label=$1
  local output="$scratch_dir/output"

  if ! (cd -- "$repo_root" && "$checker") >"$output" 2>&1; then
    printf 'FAIL: %s\n' "$label" >&2
    cat "$output" >&2
    return 1
  fi
  printf 'PASS: %s\n' "$label"
}

valid_fixture="$scratch_dir/valid"
mkdir -p "$valid_fixture/docs"
cp "$repo_root/LICENSE" "$valid_fixture/LICENSE"
cp "$repo_root/THIRD_PARTY_NOTICES.md" "$valid_fixture/THIRD_PARTY_NOTICES.md"
cp "$repo_root/docs/architecture.md" "$valid_fixture/docs/architecture.md"

expect_success "current repository passes" "$repo_root"
expect_success_without_argument "CI-style no-argument invocation passes"
expect_success "valid fixture passes" "$valid_fixture"

mkdir -p "$valid_fixture/node_modules/vendor"
printf 'TODO: third-party package documentation is not repository prose.\n' >"$valid_fixture/node_modules/vendor/README.md"
expect_success "dependency directories are excluded" "$valid_fixture"

missing_license="$scratch_dir/missing-license"
cp -R "$valid_fixture" "$missing_license"
rm "$missing_license/LICENSE"
expect_failure "missing LICENSE is rejected" "$missing_license" "LICENSE is missing or empty"

placeholder="$scratch_dir/placeholder"
cp -R "$valid_fixture" "$placeholder"
printf '\nTODO: replace this sentence.\n' >> "$placeholder/docs/architecture.md"
expect_failure "prose placeholder is rejected" "$placeholder" "unresolved placeholder"

bad_source="$scratch_dir/bad-source"
cp -R "$valid_fixture" "$bad_source"
sed -i.bak 's#https://#http://#g' "$bad_source/THIRD_PARTY_NOTICES.md"
rm "$bad_source/THIRD_PARTY_NOTICES.md.bak"
expect_failure "non-HTTPS source is rejected" "$bad_source" "canonical HTTPS source"

printf 'All repository-script tests passed.\n'
