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
mkdir -p "$fixture/.github/workflows" "$fixture/control" "$fixture/runtime/tests" "$fixture/tests/acceptance" "$fixture/viewer"

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
printf 'FROM golang:1.26.6-alpine@sha256:%s AS build\nFROM alpine:3.24@sha256:%s\n' \
  "$old_digest" "$old_digest" >"$fixture/control/Dockerfile"
printf 'FROM golang:1.26.6-trixie@sha256:%s AS build\nRUN apt-get install chromium=151.0.7922.137-1~deb13u1\n' \
  "$old_digest" >"$fixture/viewer/Dockerfile"
printf 'NEKO_IMAGE=%s\n' "$old_image" >"$fixture/runtime/.env.example"
printf '%s\n' \
  'services:' \
  '  viewer:' \
  "    image: \"\${NEKO_IMAGE:-$old_image}\"" \
  >"$fixture/runtime/docker-compose.yml"
printf "assert_contains runtime/docker-compose.yml '%s'\n" "$old_image" >"$fixture/runtime/tests/test_runtime.sh"
# These are literal lines in the generated acceptance script.
# shellcheck disable=SC2016
printf '%s\n' \
  'ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"' \
  'DEFAULT_NEKO_IMAGE_REF="$(awk -F= '\''$1 == "NEKO_IMAGE" { sub(/^[^=]*=/, ""); print; exit }'\'' "$ROOT_DIR/runtime/.env.example")"' \
  >"$fixture/tests/acceptance/run-linux-persistence.sh"

"$checker" "$fixture"

go_new_digest=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
alpine_new_digest=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
GHOSTLIGHT_GO_BASE_RESOLVED_DIGEST="sha256:$go_new_digest" \
GHOSTLIGHT_ALPINE_BASE_RESOLVED_DIGEST="sha256:$alpine_new_digest" \
  "$base_updater" --root "$fixture"
grep -Fqx -- "FROM golang:1.26.6-alpine@sha256:$go_new_digest AS build" "$fixture/control/Dockerfile" \
  || fail 'base updater did not update the Go build image'
grep -Fqx -- "FROM alpine:3.24@sha256:$alpine_new_digest" "$fixture/control/Dockerfile" \
  || fail 'base updater did not update the Alpine runtime image'
"$checker" "$fixture"

cp "$fixture/.github/workflows/ci.yml" "$scratch_dir/ci.yml"
sed -i.bak 's|actions/checkout@[0-9a-f]*|actions/checkout@v4|' "$fixture/.github/workflows/ci.yml"
rm "$fixture/.github/workflows/ci.yml.bak"
expect_failure 'mutable action tag' "$checker" "$fixture"
cp "$scratch_dir/ci.yml" "$fixture/.github/workflows/ci.yml"

sed -i.bak 's|uses: actions/checkout@[0-9a-f]*|uses : actions/checkout@v4|' "$fixture/.github/workflows/ci.yml"
rm "$fixture/.github/workflows/ci.yml.bak"
expect_failure 'mutable action with spaced key separator' "$checker" "$fixture"
cp "$scratch_dir/ci.yml" "$fixture/.github/workflows/ci.yml"

cp "$fixture/control/Dockerfile" "$scratch_dir/Dockerfile"
printf 'FROM golang:1.26.6-alpine@sha256:%s AS build\nFROM alpine:3.24\n' \
  "$old_digest" >"$fixture/control/Dockerfile"
expect_failure 'mutable Docker base image' "$checker" "$fixture"
cp "$scratch_dir/Dockerfile" "$fixture/control/Dockerfile"

cp "$fixture/control/Dockerfile" "$scratch_dir/control-Dockerfile"
sed -i.bak 's/golang:1\.26\.6-alpine/golang:1.26.5-alpine/' "$fixture/control/Dockerfile"
rm "$fixture/control/Dockerfile.bak"
expect_failure 'control Go stdlib vulnerability regression' "$checker" "$fixture"
cp "$scratch_dir/control-Dockerfile" "$fixture/control/Dockerfile"

cp "$fixture/viewer/Dockerfile" "$scratch_dir/viewer-Dockerfile"
sed -i.bak 's/golang:1\.26\.6-trixie/golang:1.25.12-trixie/' "$fixture/viewer/Dockerfile"
rm "$fixture/viewer/Dockerfile.bak"
expect_failure 'viewer Go stdlib vulnerability regression' "$checker" "$fixture"
cp "$scratch_dir/viewer-Dockerfile" "$fixture/viewer/Dockerfile"

sed -i.bak 's/151\.0\.7922\.137/151.0.7922.108/' "$fixture/viewer/Dockerfile"
rm "$fixture/viewer/Dockerfile.bak"
expect_failure 'viewer Chromium vulnerability regression' "$checker" "$fixture"
cp "$scratch_dir/viewer-Dockerfile" "$fixture/viewer/Dockerfile"

printf '%s\n' \
  'services:' \
  '  viewer:' \
  "    image: \"\${NEKO_IMAGE:-$old_image}\"" \
  '  rogue:' \
  '    image : alpine:latest' \
  >"$fixture/runtime/docker-compose.yml"
expect_failure 'mutable Compose image with spaced key separator' "$checker" "$fixture"
printf '%s\n' \
  'services:' \
  '  viewer:' \
  "    image: \"\${NEKO_IMAGE:-$old_image}\"" \
  >"$fixture/runtime/docker-compose.yml"

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
grep -Fq -- 'runtime/.env.example' "$fixture/tests/acceptance/run-linux-persistence.sh" \
  || fail 'acceptance harness must derive the default Neko pin from the environment example'
"$updater" --check --root "$fixture" "$new_image"
"$checker" "$fixture"

expect_failure 'mutable update candidate' "$updater" --root "$fixture" 'ghcr.io/m1k1o/neko/chromium:latest'
expect_failure 'wrong update repository' "$updater" --root "$fixture" "ghcr.io/example/neko@sha256:$new_digest"

owned_image="ghcr.io/evalops/ghostlight-viewer@sha256:$old_digest"
"$updater" --root "$fixture" "$owned_image"
grep -Fqx -- "NEKO_IMAGE=$owned_image" "$fixture/runtime/.env.example" \
  || fail 'updater did not accept the owned hardened viewer namespace'
"$checker" "$fixture"

actual_contract="$scratch_dir/actual-control-contract"
mkdir -p "$actual_contract/control"
cp "$script_dir/../control/Dockerfile" "$actual_contract/control/Dockerfile"
actual_go_digest=$(awk '$1 == "FROM" && $2 ~ /^golang:/ { image = $2; sub(/^[^@]*@/, "", image); print image; exit }' "$actual_contract/control/Dockerfile")
actual_alpine_digest=$(awk '$1 == "FROM" && $2 ~ /^alpine:/ { image = $2; sub(/^[^@]*@/, "", image); print image; exit }' "$actual_contract/control/Dockerfile")
before_update=$(shasum -a 256 "$actual_contract/control/Dockerfile")
GHOSTLIGHT_GO_BASE_RESOLVED_DIGEST="$actual_go_digest" \
GHOSTLIGHT_ALPINE_BASE_RESOLVED_DIGEST="$actual_alpine_digest" \
  "$base_updater" --root "$actual_contract"
after_update=$(shasum -a 256 "$actual_contract/control/Dockerfile")
[[ "$before_update" == "$after_update" ]] \
  || fail 'base updater changed the checked-in control base contract'

printf 'image safety tests passed\n'
