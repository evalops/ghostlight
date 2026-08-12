#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)
workflow="$repo_root/.github/workflows/browser-update.yml"

[[ -s "$workflow" ]] || {
  printf 'browser update workflow is missing\n' >&2
  exit 1
}

require_text() {
  local text=$1
  grep -Fq -- "$text" "$workflow" || {
    printf 'browser update workflow is missing required contract: %s\n' "$text" >&2
    exit 1
  }
}

require_text 'continue-on-error: true'
require_text 'bash scripts/update-neko-image.sh'
require_text 'bash scripts/update-control-base-images.sh'
require_text 'needs: candidate'
require_text "if: github.event_name != 'pull_request'"
dollar='$'
require_text "CANDIDATE_IMAGE: ${dollar}{{ needs.candidate.outputs.neko-image }}"
require_text "GO_BASE_IMAGE: ${dollar}{{ needs.candidate.outputs.go-image }}"
require_text "ALPINE_BASE_IMAGE: ${dollar}{{ needs.candidate.outputs.alpine-image }}"
require_text 'tests/acceptance/run-linux-persistence.sh'
require_text 'Create the protected update pull request'
require_text 'image --scanners vuln --format json'
require_text '--exit-code 1 --severity HIGH,CRITICAL --ignore-unfixed'

if grep -Fq -- "if: steps.base-drift.outcome == 'failure'" "$workflow"; then
  printf 'digest drift must not fail a verified candidate before the proposal job\n' >&2
  exit 1
fi

proposal=$(awk '/^  propose-update:/ { in_proposal = 1 } in_proposal { print }' "$workflow")
if grep -Fq -- 'resolve-image-digest.sh' <<<"$proposal"; then
  printf 'proposal job must consume tested candidate outputs without re-resolving tags\n' >&2
  exit 1
fi
grep -Fq -- "GHOSTLIGHT_GO_BASE_RESOLVED_DIGEST=\"${dollar}go_digest\"" <<<"$proposal" || {
  printf 'proposal job does not apply the tested Go base digest\n' >&2
  exit 1
}
grep -Fq -- "GHOSTLIGHT_ALPINE_BASE_RESOLVED_DIGEST=\"${dollar}alpine_digest\"" <<<"$proposal" || {
  printf 'proposal job does not apply the tested Alpine base digest\n' >&2
  exit 1
}

printf 'browser update workflow dependency and outcome contract passed\n'
