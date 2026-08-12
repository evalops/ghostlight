#!/usr/bin/env bash

set -euo pipefail

RUNTIME_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="$(cd -- "$RUNTIME_DIR/.." && pwd)"

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

expect_failure() {
  local label="$1"
  shift
  if "$@" >"$root_compose_fixture/failure-output" 2>&1; then
    fail "$label unexpectedly passed"
  fi
}

for path in \
  "$RUNTIME_DIR/docker-compose.yml" \
  "$REPO_DIR/compose.yaml" \
  "$RUNTIME_DIR/.env.example" \
  "$RUNTIME_DIR/chromium-policy.json" \
  "$RUNTIME_DIR/README.md" \
  "$RUNTIME_DIR/bin/find-placeholders.sh" \
  "$RUNTIME_DIR/bin/preflight.sh" \
  "$RUNTIME_DIR/bin/smoke.sh" \
  "$RUNTIME_DIR/bin/profile-backup.sh" \
  "$RUNTIME_DIR/tests/test_profile_backup.sh"; do
  assert_file "$path"
done
assert_file "$REPO_DIR/macos/package-app.sh"

assert_contains "$RUNTIME_DIR/docker-compose.yml" 'ghcr.io/m1k1o/neko/chromium@sha256:a79093411aced75b3ed7110d50ec9082f9933afabd6592254f01c383678082e7'
assert_contains "$RUNTIME_DIR/docker-compose.yml" 'context: ../control'
# This is a literal Compose interpolation expression, not a shell expansion.
# shellcheck disable=SC2016
assert_contains "$RUNTIME_DIR/docker-compose.yml" 'host_ip: "${GHOSTLIGHT_BIND_ADDRESS:?set GHOSTLIGHT_BIND_ADDRESS to a private host interface}"'
assert_contains "$RUNTIME_DIR/docker-compose.yml" 'target: 8080'
assert_contains "$RUNTIME_DIR/docker-compose.yml" 'shm_size: "2gb"'
assert_contains "$RUNTIME_DIR/docker-compose.yml" 'restart: unless-stopped'
assert_contains "$RUNTIME_DIR/docker-compose.yml" '/home/neko/.config/chromium'
assert_contains "$RUNTIME_DIR/docker-compose.yml" 'hostname: ghostlight-chromium'
assert_contains "$RUNTIME_DIR/docker-compose.yml" '/etc/chromium/policies/managed/policies.json:ro'
assert_contains "$RUNTIME_DIR/docker-compose.yml" 'GHOSTLIGHT_VIEWER_URL'
assert_contains "$RUNTIME_DIR/docker-compose.yml" 'GHOSTLIGHT_VIEWER_HEALTH_URL'
assert_contains "$RUNTIME_DIR/docker-compose.yml" 'NEKO_SERVER_BIND: "0.0.0.0:8080"'
assert_contains "$RUNTIME_DIR/docker-compose.yml" 'healthcheck:'
assert_contains "$RUNTIME_DIR/docker-compose.yml" 'http://127.0.0.1:8080/health'
assert_contains "$RUNTIME_DIR/docker-compose.yml" '/v1/viewer'
assert_contains "$RUNTIME_DIR/docker-compose.yml" 'http://127.0.0.1:8080/readyz'

assert_contains "$RUNTIME_DIR/.env.example" '__GENERATE_AT_INSTALL__'
assert_contains "$RUNTIME_DIR/.env.example" 'GHOSTLIGHT_VIEWER_HEALTH_URL=http://viewer:8080'
python3 - "$RUNTIME_DIR/chromium-policy.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as policy_file:
    policy = json.load(policy_file)

assert policy.get("DefaultCookiesSetting") == 1
assert policy.get("RestoreOnStartup") == 1
PY
assert_contains "$RUNTIME_DIR/README.md" 'Apache-2.0'
assert_contains "$RUNTIME_DIR/README.md" 'UDP'
assert_contains "$RUNTIME_DIR/README.md" 'TCP'
assert_contains "$RUNTIME_DIR/bin/preflight.sh" 'docker compose'
assert_contains "$RUNTIME_DIR/bin/preflight.sh" 'GHOSTLIGHT_BIND_ADDRESS'
assert_contains "$RUNTIME_DIR/bin/preflight.sh" 'uid 1000'
assert_contains "$RUNTIME_DIR/bin/smoke.sh" '/readyz'
assert_contains "$RUNTIME_DIR/bin/smoke.sh" '/v1/viewer'
assert_contains "$RUNTIME_DIR/bin/smoke.sh" '/health'
assert_contains "$RUNTIME_DIR/bin/smoke.sh" 'viewer'
assert_contains "$RUNTIME_DIR/bin/profile-backup.sh" 'checksum'

[[ -x "$RUNTIME_DIR/bin/preflight.sh" ]] || fail "preflight.sh must be executable"
[[ -x "$RUNTIME_DIR/bin/smoke.sh" ]] || fail "smoke.sh must be executable"

placeholder_fixture="$(mktemp)"
root_compose_fixture="$(mktemp -d)"
trap 'rm -f "$placeholder_fixture"; rm -rf "$root_compose_fixture"' EXIT
printf '# __GENERATE_AT_INSTALL__ is allowed in comments\nNEKO_USER_PASSWORD=configured\n' >"$placeholder_fixture"
if "$RUNTIME_DIR/bin/find-placeholders.sh" "$placeholder_fixture"; then
  fail "comment-only placeholder must not block a configured environment"
fi
printf 'NEKO_USER_PASSWORD=configured # __GENERATE_AT_INSTALL__ is allowed in an inline comment\n' >"$placeholder_fixture"
if "$RUNTIME_DIR/bin/find-placeholders.sh" "$placeholder_fixture"; then
  fail "inline comment placeholder must not block an unquoted configured value"
fi
printf 'NEKO_USER_PASSWORD="configured" # __GENERATE_AT_INSTALL__ is allowed after a quoted value\n' >"$placeholder_fixture"
if "$RUNTIME_DIR/bin/find-placeholders.sh" "$placeholder_fixture"; then
  fail "inline comment placeholder must not block a quoted configured value"
fi
printf 'NEKO_USER_PASSWORD=__GENERATE_AT_INSTALL__\n' >"$placeholder_fixture"
"$RUNTIME_DIR/bin/find-placeholders.sh" "$placeholder_fixture" >/dev/null \
  || fail "assignment placeholder must be detected"
printf 'NEKO_USER_PASSWORD="__GENERATE_AT_INSTALL__" # configured later\n' >"$placeholder_fixture"
"$RUNTIME_DIR/bin/find-placeholders.sh" "$placeholder_fixture" >/dev/null \
  || fail "quoted assignment placeholder must be detected"

fake_bin="$root_compose_fixture/bin"
profile_fixture="$root_compose_fixture/profile"
env_fixture="$root_compose_fixture/runtime.env"
docker_log="$root_compose_fixture/docker.log"
mkdir -p "$fake_bin"
mkdir -m 700 "$profile_fixture"
# These are literal lines in the generated fake Docker script.
# shellcheck disable=SC2016
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "%s\n" "$*" >>"${FAKE_DOCKER_LOG:?}"' \
  'if [[ "${1:-}" == run && "${FAKE_DOCKER_FAIL_RUN:-0}" == 1 ]]; then exit 1; fi' \
  'exit 0' >"$fake_bin/docker"
chmod 700 "$fake_bin/docker"
sed \
  -e 's|GHOSTLIGHT_BIND_ADDRESS=.*|GHOSTLIGHT_BIND_ADDRESS=127.0.0.1|' \
  -e 's|GHOSTLIGHT_VIEWER_URL=.*|GHOSTLIGHT_VIEWER_URL=http://127.0.0.1:8081|' \
  -e 's|NEKO_USER_PASSWORD=.*|NEKO_USER_PASSWORD=test-user-password|' \
  -e 's|NEKO_ADMIN_PASSWORD=.*|NEKO_ADMIN_PASSWORD=test-admin-password|' \
  -e 's|NEKO_WEBRTC_NAT1TO1=.*|NEKO_WEBRTC_NAT1TO1=127.0.0.1|' \
  "$RUNTIME_DIR/.env.example" >"$env_fixture"
chmod 600 "$env_fixture"
PATH="$fake_bin:$PATH" GHOSTLIGHT_ENV_FILE="$env_fixture" CHROMIUM_PROFILE_DIR="$profile_fixture" \
  FAKE_DOCKER_LOG="$docker_log" "$RUNTIME_DIR/bin/preflight.sh" >/dev/null
grep --fixed-strings -- 'run --rm --user 1000:1000' "$docker_log" >/dev/null \
  || fail "preflight must verify profile writability as viewer uid 1000"
expect_failure "uid 1000 profile write denial" env PATH="$fake_bin:$PATH" GHOSTLIGHT_ENV_FILE="$env_fixture" \
  CHROMIUM_PROFILE_DIR="$profile_fixture" FAKE_DOCKER_LOG="$docker_log" FAKE_DOCKER_FAIL_RUN=1 "$RUNTIME_DIR/bin/preflight.sh"

chmod 640 "$env_fixture"
expect_failure "group-readable environment" env PATH="$fake_bin:$PATH" GHOSTLIGHT_ENV_FILE="$env_fixture" \
  CHROMIUM_PROFILE_DIR="$profile_fixture" FAKE_DOCKER_LOG="$docker_log" GHOSTLIGHT_SKIP_PROFILE_RUNTIME_CHECK=1 "$RUNTIME_DIR/bin/preflight.sh"
chmod 600 "$env_fixture"
sed -i.bak 's|GHOSTLIGHT_BIND_ADDRESS=127.0.0.1|GHOSTLIGHT_BIND_ADDRESS=0.0.0.0|' "$env_fixture"
rm "$env_fixture.bak"
expect_failure "wildcard bind address" env PATH="$fake_bin:$PATH" GHOSTLIGHT_ENV_FILE="$env_fixture" \
  CHROMIUM_PROFILE_DIR="$profile_fixture" FAKE_DOCKER_LOG="$docker_log" GHOSTLIGHT_SKIP_PROFILE_RUNTIME_CHECK=1 "$RUNTIME_DIR/bin/preflight.sh"
sed -i.bak 's|GHOSTLIGHT_BIND_ADDRESS=0.0.0.0|GHOSTLIGHT_BIND_ADDRESS=127.0.0.1|' "$env_fixture"
rm "$env_fixture.bak"
chmod 750 "$profile_fixture"
expect_failure "group-readable profile" env PATH="$fake_bin:$PATH" GHOSTLIGHT_ENV_FILE="$env_fixture" \
  CHROMIUM_PROFILE_DIR="$profile_fixture" FAKE_DOCKER_LOG="$docker_log" GHOSTLIGHT_SKIP_PROFILE_RUNTIME_CHECK=1 "$RUNTIME_DIR/bin/preflight.sh"
chmod 700 "$profile_fixture"

bash -n "$RUNTIME_DIR/bin/find-placeholders.sh"
bash -n "$RUNTIME_DIR/bin/preflight.sh"
bash -n "$RUNTIME_DIR/bin/smoke.sh"
bash -n "$RUNTIME_DIR/bin/profile-backup.sh"
bash -n "$RUNTIME_DIR/tests/test_profile_backup.sh"
bash -n "$REPO_DIR/macos/package-app.sh"

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "$RUNTIME_DIR/bin/find-placeholders.sh" "$RUNTIME_DIR/bin/preflight.sh" "$RUNTIME_DIR/bin/smoke.sh" "$RUNTIME_DIR/bin/profile-backup.sh" "$RUNTIME_DIR/tests/test_profile_backup.sh" "$REPO_DIR/macos/package-app.sh"
fi

bash "$RUNTIME_DIR/tests/test_profile_backup.sh"

expected_neko_image="$(awk -F= '$1 == "NEKO_IMAGE" { sub(/^[^=]*=/, ""); print; exit }' "$RUNTIME_DIR/.env.example")"
[[ "$expected_neko_image" == *@sha256:* ]] || fail "NEKO_IMAGE in .env.example must be digest-pinned"
resolved_images="$(cd "$RUNTIME_DIR" && docker compose --env-file .env.example -f docker-compose.yml config --images)"
grep --fixed-strings --line-regexp -- "$expected_neko_image" <<<"$resolved_images" >/dev/null \
  || fail "Compose viewer image must resolve to NEKO_IMAGE from .env.example"
(cd "$RUNTIME_DIR" && docker compose --env-file .env.example -f docker-compose.yml config --quiet)

resolved_runtime="$(cd "$RUNTIME_DIR" && docker compose --env-file .env.example -f docker-compose.yml config)"
grep --fixed-strings -- "source: $RUNTIME_DIR/data/chromium" <<<"$resolved_runtime" >/dev/null \
  || fail "Compose viewer profile must resolve to runtime/data/chromium"
grep --fixed-strings -- 'target: /home/neko/.config/chromium' <<<"$resolved_runtime" >/dev/null \
  || fail "Compose viewer profile target must remain the Chromium profile directory"
grep --fixed-strings -- 'target: /etc/chromium/policies/managed/policies.json' <<<"$resolved_runtime" >/dev/null \
  || fail "Compose must mount the persistent Chromium policy"
grep --fixed-strings -- 'NEKO_SERVER_BIND: 0.0.0.0:8080' <<<"$resolved_runtime" >/dev/null \
  || fail "Neko must accept readiness probes from the private Compose network"

mkdir -p "$root_compose_fixture/runtime" "$root_compose_fixture/control"
cp "$REPO_DIR/compose.yaml" "$root_compose_fixture/compose.yaml"
cp "$RUNTIME_DIR/docker-compose.yml" "$root_compose_fixture/runtime/docker-compose.yml"
cp "$RUNTIME_DIR/chromium-policy.json" "$root_compose_fixture/runtime/chromium-policy.json"
cp "$RUNTIME_DIR/.env.example" "$root_compose_fixture/runtime/.env"
cp "$REPO_DIR/control/Dockerfile" "$root_compose_fixture/control/Dockerfile"
sed -i.bak \
  -e 's|GHOSTLIGHT_BIND_ADDRESS=.*|GHOSTLIGHT_BIND_ADDRESS=127.0.0.1|' \
  -e 's|GHOSTLIGHT_VIEWER_URL=.*|GHOSTLIGHT_VIEWER_URL=http://192.0.2.10:8081|' \
  -e 's|NEKO_USER_PASSWORD=.*|NEKO_USER_PASSWORD=test-user-password|' \
  -e 's|NEKO_ADMIN_PASSWORD=.*|NEKO_ADMIN_PASSWORD=test-admin-password|' \
  -e 's|NEKO_WEBRTC_NAT1TO1=.*|NEKO_WEBRTC_NAT1TO1=192.0.2.10|' \
  "$root_compose_fixture/runtime/.env"
rm "$root_compose_fixture/runtime/.env.bak"
root_runtime="$(cd "$root_compose_fixture" && docker compose config)"
grep --fixed-strings -- 'GHOSTLIGHT_VIEWER_URL: http://192.0.2.10:8081' <<<"$root_runtime" >/dev/null \
  || fail "flag-free root Compose must load runtime/.env"
grep --fixed-strings -- 'NEKO_MEMBER_MULTIUSER_USER_PASSWORD: test-user-password' <<<"$root_runtime" >/dev/null \
  || fail "flag-free root Compose must configure the viewer password"
grep --fixed-strings -- 'NEKO_WEBRTC_NAT1TO1: 192.0.2.10' <<<"$root_runtime" >/dev/null \
  || fail "flag-free root Compose must configure the reachable WebRTC address"
grep --fixed-strings -- 'host_ip: 127.0.0.1' <<<"$root_runtime" >/dev/null \
  || fail "flag-free root Compose must bind published ports to GHOSTLIGHT_BIND_ADDRESS"

printf 'runtime tests passed\n'
