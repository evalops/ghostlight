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

[[ -d "$repo_root" ]] || {
  printf 'repository root is not a directory: %s\n' "$repo_root" >&2
  exit 2
}
repo_root=$(cd -- "$repo_root" && pwd)

failures=0
required_files=(
  .github/workflows/ci.yml
  control/Dockerfile
  runtime/.env.example
  runtime/docker-compose.yml
  runtime/tests/test_runtime.sh
  tests/acceptance/run-linux-persistence.sh
)

for relative_path in "${required_files[@]}"; do
  if [[ ! -f "$repo_root/$relative_path" ]]; then
    printf 'required image-safety input is missing: %s\n' "$relative_path" >&2
    failures=$((failures + 1))
  fi
done

if (( failures > 0 )); then
  exit 1
fi

neko_image=$(awk -F= '$1 == "NEKO_IMAGE" { sub(/^[^=]*=/, ""); print; exit }' "$repo_root/runtime/.env.example")
if [[ ! "$neko_image" =~ ^ghcr\.io/(m1k1o/neko/chromium|evalops/ghostlight-viewer)@sha256:[0-9a-f]{64}$ ]]; then
  printf 'runtime/.env.example NEKO_IMAGE is not a canonical digest pin: %s\n' "$neko_image" >&2
  failures=$((failures + 1))
else
  for relative_path in runtime/docker-compose.yml runtime/tests/test_runtime.sh; do
    if ! grep -Fq -- "$neko_image" "$repo_root/$relative_path"; then
      printf '%s does not use the NEKO_IMAGE digest from runtime/.env.example\n' "$relative_path" >&2
      failures=$((failures + 1))
    fi
  done
  if ! grep -Fq -- 'runtime/.env.example' "$repo_root/tests/acceptance/run-linux-persistence.sh"; then
    printf 'tests/acceptance/run-linux-persistence.sh does not derive its default Neko image from runtime/.env.example\n' >&2
    failures=$((failures + 1))
  fi
  if grep -Eq 'ghcr\.io/(m1k1o/neko/chromium|evalops/ghostlight-viewer)@sha256:[0-9a-f]{64}' "$repo_root/tests/acceptance/run-linux-persistence.sh"; then
    printf 'tests/acceptance/run-linux-persistence.sh contains a stale-prone hardcoded Neko digest\n' >&2
    failures=$((failures + 1))
  fi
fi

compose_count=0
while IFS= read -r -d '' compose_file; do
  compose_count=$((compose_count + 1))
  while IFS= read -r image_line; do
    image_ref=$(sed -E 's/^[[:space:]]*image[[:space:]]*:[[:space:]]*//' <<<"$image_line")
    if [[ ! "$image_ref" =~ @sha256:[0-9a-f]{64} ]]; then
      printf '%s has a non-digest-pinned image: %s\n' "${compose_file#"$repo_root/"}" "$image_ref" >&2
      failures=$((failures + 1))
    fi
  done < <(grep -E '^[[:space:]]*image[[:space:]]*:' "$compose_file" || true)
done < <(find "$repo_root" -type f \( -name 'compose.yml' -o -name 'compose.yaml' -o -name 'docker-compose.yml' -o -name 'docker-compose.yaml' \) -not -path "$repo_root/.git/*" -print0)

if (( compose_count == 0 )); then
  printf 'no Compose files found to validate\n' >&2
  failures=$((failures + 1))
fi

workflow_count=0
while IFS= read -r -d '' workflow; do
  workflow_count=$((workflow_count + 1))
  while IFS= read -r action_line; do
    action_ref=$(sed -E 's/^[[:space:]]*(-[[:space:]]*)?uses[[:space:]]*:[[:space:]]*//' <<<"$action_line")
    action_ref=${action_ref%%#*}
    action_ref=${action_ref//\"/}
    action_ref=${action_ref//\'/}
    action_ref=$(printf '%s' "$action_ref" | xargs)
    if [[ "$action_ref" == ./* ]]; then
      continue
    fi
    if [[ ! "$action_ref" =~ ^[^[:space:]@]+@[0-9a-f]{40}$ ]]; then
      printf '%s has a non-SHA-pinned action: %s\n' "${workflow#"$repo_root/"}" "$action_ref" >&2
      failures=$((failures + 1))
    fi
  done < <(grep -E '^[[:space:]]*(-[[:space:]]*)?uses[[:space:]]*:' "$workflow" || true)
done < <(find "$repo_root/.github/workflows" -type f \( -name '*.yml' -o -name '*.yaml' \) -print0)

if (( workflow_count == 0 )); then
  printf 'no GitHub Actions workflows found under .github/workflows\n' >&2
  failures=$((failures + 1))
fi

dockerfile_count=0
while IFS= read -r -d '' dockerfile; do
  dockerfile_count=$((dockerfile_count + 1))
  while IFS= read -r from_line; do
    image_ref=$(awk '{ print $2 }' <<<"$from_line")
    if [[ "$image_ref" == scratch ]]; then
      continue
    fi
    if [[ ! "$image_ref" =~ @sha256:[0-9a-f]{64}$ ]]; then
      printf '%s has a non-digest-pinned base image: %s\n' "${dockerfile#"$repo_root/"}" "$image_ref" >&2
      failures=$((failures + 1))
    fi
  done < <(grep -Ei '^[[:space:]]*FROM[[:space:]]+' "$dockerfile" || true)
done < <(find "$repo_root" -type f -name 'Dockerfile*' -not -path "$repo_root/.git/*" -print0)

if (( dockerfile_count == 0 )); then
  printf 'no Dockerfiles found to validate\n' >&2
  failures=$((failures + 1))
fi

if (( failures > 0 )); then
  printf 'image safety check failed with %d issue(s)\n' "$failures" >&2
  exit 1
fi

printf 'image and GitHub Action pins are consistent and immutable\n'
