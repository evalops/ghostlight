#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
checker="$script_dir/check-image-safety.sh"
updater="$script_dir/update-neko-image.sh"
base_updater="$script_dir/update-control-base-images.sh"
scratch_dir=$(mktemp -d)
trap 'rm -rf "$scratch_dir"' EXIT

fail() {
  printf 'image safety test failed: %s\n' "$*" >&2
  exit 1
}

expect_failure() {
  local label=$1
  shift
  if "$@" >"$scratch_dir/output" 2>&1; then
    fail "$label unexpectedly passed"
  fi
}

fixture="$scratch_dir/repository"
mkdir -p "$fixture/.github/workflows" "$fixture/control" "$fixture/runtime/tests"

old_digest=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
new_digest=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
old_image="ghcr.io/m1k1o/neko/chromium@sha256:$old_digest"
new_image="ghcr.io/m1k1o/neko/chromium@sha256:$new_digest"

printf '%s\n' \
  'name: test' \
  'on: push' \
  'jobs:' \
  '  test:' \
  '    runs-on: ubuntu-24.04' \
  '    steps:' \
  '      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683' \
  >"$fixture/.github/workflows/ci.yml"
printf 'FROM golang:1.25.12-alpine@sha256:%s AS build\nFROM alpine:3.22@sha256:%s\n' \
  "$old_digest" "$old_digest" >"$fixture/control/Dockerfile"
printf 'NEKO_IMAGE=%s\n' "$old_image" >"$fixture/runtime/.env.example"
printf '%s\n' \
  'services:' \
  '  viewer:' \
  "    image: \"\${NEKO_IMAGE:-$old_image}\"" \
  >"$fixture/runtime/docker-compose.yml"
printf "assert_contains runtime/docker-compose.yml '%s'\n" "$old_image" >"$fixture/runtime/tests/test_runtime.sh"

"$checker" "$fixture"

go_new_digest=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
alpine_new_digest=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
GHOSTLIGHT_GO_BASE_RESOLVED_DIGEST="sha256:$go_new_digest" \
GHOSTLIGHT_ALPINE_BASE_RESOLVED_DIGEST="sha256:$alpine_new_digest" \
  "$base_updater" --root "$fixture"
grep -Fqx -- "FROM golang:1.25.12-alpine@sha256:$go_new_digest AS build" "$fixture/control/Dockerfile" \
  || fail 'base updater did not update the Go build image'
grep -Fqx -- "FROM alpine:3.22@sha256:$alpine_new_digest" "$fixture/control/Dockerfile" \
  || fail 'base updater did not update the Alpine runtime image'
"$checker" "$fixture"

cp "$fixture/.github/workflows/ci.yml" "$scratch_dir/ci.yml"
sed -i.bak 's|actions/checkout@[0-9a-f]*|actions/checkout@v4|' "$fixture/.github/workflows/ci.yml"
rm "$fixture/.github/workflows/ci.yml.bak"
expect_failure 'mutable action tag' "$checker" "$fixture"
cp "$scratch_dir/ci.yml" "$fixture/.github/workflows/ci.yml"

cp "$fixture/control/Dockerfile" "$scratch_dir/Dockerfile"
printf 'FROM golang:1.25.12-alpine@sha256:%s AS build\nFROM alpine:3.22\n' \
  "$old_digest" >"$fixture/control/Dockerfile"
expect_failure 'mutable Docker base image' "$checker" "$fixture"
cp "$scratch_dir/Dockerfile" "$fixture/control/Dockerfile"

sed -i.bak "s|$old_image|$new_image|" "$fixture/runtime/.env.example"
rm "$fixture/runtime/.env.example.bak"
expect_failure 'inconsistent Neko pin' "$checker" "$fixture"
sed -i.bak "s|$new_image|$old_image|" "$fixture/runtime/.env.example"
rm "$fixture/runtime/.env.example.bak"

"$updater" --root "$fixture" "$new_image"
grep -Fqx -- "NEKO_IMAGE=$new_image" "$fixture/runtime/.env.example" \
  || fail 'updater did not replace the environment pin'
grep -Fq -- "$new_image" "$fixture/runtime/docker-compose.yml" \
  || fail 'updater did not replace the Compose fallback pin'
grep -Fq -- "$new_image" "$fixture/runtime/tests/test_runtime.sh" \
  || fail 'updater did not replace the runtime assertion pin'
"$updater" --check --root "$fixture" "$new_image"
"$checker" "$fixture"

expect_failure 'mutable update candidate' "$updater" --root "$fixture" 'ghcr.io/m1k1o/neko/chromium:latest'
expect_failure 'wrong update repository' "$updater" --root "$fixture" "ghcr.io/example/neko@sha256:$new_digest"

printf 'image safety tests passed\n'
