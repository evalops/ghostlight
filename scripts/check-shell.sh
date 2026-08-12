#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)
shell_pattern='^#!.*[[:space:]](ba)?sh([[:space:]]|$)'

if (( $# == 0 )); then
  directories=("$repo_root/scripts" "$repo_root/runtime")
else
  directories=()
  for directory in "$@"; do
    if [[ "$directory" = /* ]]; then
      directories+=("$directory")
    else
      directories+=("$repo_root/$directory")
    fi
  done
fi

shell_files=()
for directory in "${directories[@]}"; do
  if [[ ! -d "$directory" ]]; then
    continue
  fi
  while IFS= read -r -d '' file; do
    if [[ "$file" == *.sh ]] || grep -qE "$shell_pattern" "$file"; then
      shell_files+=("$file")
    fi
  done < <(find "$directory" -type f -print0)
done

if (( ${#shell_files[@]} == 0 )); then
  printf 'No shell scripts found in the requested directories.\n'
  exit 0
fi

if ! command -v shellcheck >/dev/null 2>&1; then
  printf 'ShellCheck is required to validate %d shell script(s).\n' "${#shell_files[@]}" >&2
  exit 1
fi

shellcheck "${shell_files[@]}"
printf 'ShellCheck passed for %d shell script(s).\n' "${#shell_files[@]}"
