#!/usr/bin/env bash

set -euo pipefail

RUNTIME_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'runtime test failed: %s\n' "$*" >&2
  exit 1
}

assert_file() {
  local path="$1"
  [[ -f "$path" ]] || fail "expected file: $path"
}

assert_contains() {
  local path="$1"
  local needle="$2"
  grep --fixed-strings --line-number -- "$needle" "$path" >/dev/null \
    || fail "expected ${path} to contain: ${needle}"
}

for path in \
  "$RUNTIME_DIR/docker-compose.yml" \
  "$RUNTIME_DIR/.env.example" \
  "$RUNTIME_DIR/README.md" \
  "$RUNTIME_DIR/bin/preflight.sh" \
  "$RUNTIME_DIR/bin/smoke.sh"; do
  assert_file "$path"
done

assert_contains "$RUNTIME_DIR/docker-compose.yml" 'ghcr.io/m1k1o/neko/chromium:3.1.0'
assert_contains "$RUNTIME_DIR/docker-compose.yml" 'context: ../control'
assert_contains "$RUNTIME_DIR/docker-compose.yml" '"${CONTROL_PORT:-8080}:8080"'
assert_contains "$RUNTIME_DIR/docker-compose.yml" '"${VIEWER_PORT:-8081}:8080"'
assert_contains "$RUNTIME_DIR/docker-compose.yml" 'shm_size: "2gb"'
assert_contains "$RUNTIME_DIR/docker-compose.yml" 'restart: unless-stopped'
assert_contains "$RUNTIME_DIR/docker-compose.yml" '/home/neko/.config/chromium'
assert_contains "$RUNTIME_DIR/docker-compose.yml" 'GHOSTLIGHT_VIEWER_URL'
assert_contains "$RUNTIME_DIR/docker-compose.yml" 'healthcheck:'
assert_contains "$RUNTIME_DIR/docker-compose.yml" 'wget -q -O /dev/null http://127.0.0.1:8080/healthz'
assert_contains "$RUNTIME_DIR/docker-compose.yml" '/v1/sessions'

assert_contains "$RUNTIME_DIR/.env.example" '__GENERATE_AT_INSTALL__'
assert_contains "$RUNTIME_DIR/README.md" 'Apache-2.0'
assert_contains "$RUNTIME_DIR/README.md" 'UDP'
assert_contains "$RUNTIME_DIR/README.md" 'TCP'
assert_contains "$RUNTIME_DIR/bin/preflight.sh" 'docker compose'
assert_contains "$RUNTIME_DIR/bin/smoke.sh" '/healthz'
assert_contains "$RUNTIME_DIR/bin/smoke.sh" '/v1/sessions'
assert_contains "$RUNTIME_DIR/bin/smoke.sh" 'viewer'

[[ -x "$RUNTIME_DIR/bin/preflight.sh" ]] || fail "preflight.sh must be executable"
[[ -x "$RUNTIME_DIR/bin/smoke.sh" ]] || fail "smoke.sh must be executable"

bash -n "$RUNTIME_DIR/bin/preflight.sh"
bash -n "$RUNTIME_DIR/bin/smoke.sh"

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "$RUNTIME_DIR/bin/preflight.sh" "$RUNTIME_DIR/bin/smoke.sh"
fi

(cd "$RUNTIME_DIR" && docker compose --env-file .env.example -f docker-compose.yml config --quiet)

printf 'runtime tests passed\n'
