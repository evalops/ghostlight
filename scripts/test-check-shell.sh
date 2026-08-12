#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
checker="$script_dir/check-shell.sh"
scratch_dir=$(mktemp -d)
trap 'rm -rf "$scratch_dir"' EXIT

fixture="$scratch_dir/fixture"
fake_bin="$scratch_dir/bin"
log_file="$scratch_dir/shellcheck-args"
mkdir -p "$fixture/scripts/nested" "$fixture/runtime" "$fake_bin"

printf '#!/usr/bin/env bash\nexit 0\n' > "$fixture/scripts/nested/run-script"
printf '#!/bin/sh\nexit 0\n' > "$fixture/runtime/run.sh"
printf 'documentation\n' > "$fixture/scripts/nested/README.txt"

printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > %q\n' "$log_file" > "$fake_bin/shellcheck"
chmod +x "$fake_bin/shellcheck"

if ! PATH="$fake_bin:$PATH" "$checker" "$fixture/scripts" "$fixture/runtime"; then
  printf 'FAIL: checker rejected the fixture\n' >&2
  exit 1
fi

if ! grep -Fqx -- "$fixture/scripts/nested/run-script" "$log_file"; then
  printf 'FAIL: shebang-only script was not checked\n' >&2
  exit 1
fi
if ! grep -Fqx -- "$fixture/runtime/run.sh" "$log_file"; then
  printf 'FAIL: .sh script was not checked\n' >&2
  exit 1
fi
if grep -Fq -- "$fixture/scripts/nested/README.txt" "$log_file"; then
  printf 'FAIL: non-shell file was checked\n' >&2
  exit 1
fi

if ! "$checker" "$scratch_dir/absent" > "$scratch_dir/skip-output"; then
  printf 'FAIL: absent directory did not skip cleanly\n' >&2
  exit 1
fi
grep -Fq -- 'No shell scripts found' "$scratch_dir/skip-output"

printf 'All shell-checker tests passed.\n'
