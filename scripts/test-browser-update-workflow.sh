#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)
workflow="$repo_root/.github/workflows/browser-update.yml"
ci_workflow="$repo_root/.github/workflows/ci.yml"
acceptance="$repo_root/tests/acceptance/run-linux-persistence.sh"

[[ -s "$workflow" ]] || {
  printf 'browser update workflow is missing\n' >&2
  exit 1
}
[[ -s "$ci_workflow" ]] || {
  printf 'CI workflow is missing\n' >&2
  exit 1
}
[[ -s "$acceptance" ]] || {
  printf 'Linux persistence acceptance harness is missing\n' >&2
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
require_text 'GHOSTLIGHT_ACCEPTANCE_SHARE_VIEWER_NETWORK: "0"'
require_text "tested_tree=\$(git rev-parse 'HEAD^{tree}')"
require_text "remote_tree=\$(git rev-parse 'FETCH_HEAD^{tree}')"
require_text 'gh pr list'
require_text 'gh pr create'

# These are literal workflow source contracts, not shell expansions.
# shellcheck disable=SC2016
tree_check_line=$(grep -nF -- '[[ "$remote_tree" == "$tested_tree" ]]' "$workflow" | cut -d: -f1)
# shellcheck disable=SC2016
pr_lookup_line=$(grep -nF -- 'open_pr=$(gh pr list' "$workflow" | cut -d: -f1)
if [[ -z "$tree_check_line" || -z "$pr_lookup_line" || "$tree_check_line" -ge "$pr_lookup_line" ]]; then
  printf 'existing update branches must match the tested tree before PR recovery\n' >&2
  exit 1
fi
if grep -Fq -- 'The tested update branch already exists' "$workflow"; then
  printf 'existing update branches must not bypass pull-request recovery\n' >&2
  exit 1
fi

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

grep -Fq -- 'GHOSTLIGHT_ACCEPTANCE_SHARE_VIEWER_NETWORK:-0' "$acceptance" || {
  printf 'acceptance harness does not default to the stock Compose network topology\n' >&2
  exit 1
}
grep -Fq -- 'if (( share_viewer_network == 1 )); then' "$acceptance" || {
  printf 'acceptance harness does not make the shared viewer network opt-in\n' >&2
  exit 1
}
# These are literal source-contract assertions, not shell expansions.
# shellcheck disable=SC2016
for setting in \
  'NEKO_DESKTOP_SCREEN=1920x1080@30' \
  'NEKO_WEBRTC_UDPMUX=$WEBRTC_PORT' \
  'NEKO_WEBRTC_TCPMUX=$WEBRTC_PORT' \
  'NEKO_WEBRTC_ICELITE=0'; do
  grep -Fq -- "$setting" "$acceptance" || {
    printf 'acceptance harness does not align rendered Neko setting: %s\n' "$setting" >&2
    exit 1
  }
done
# This is a literal source-contract assertion, not a shell expansion.
# shellcheck disable=SC2016
if grep -Fq -- 'down --remove-orphans >>"$TRANSCRIPT" 2>&1 || true' "$acceptance"; then
  printf 'acceptance harness still suppresses Compose cleanup failures\n' >&2
  exit 1
fi
grep -Fq -- 'cleanup failed; acceptance result changed to failure' "$acceptance" || {
  printf 'acceptance harness does not propagate cleanup failures\n' >&2
  exit 1
}

# This is a literal GitHub Actions interpolation expression.
# shellcheck disable=SC2016
grep -Fq -- 'name: committed-acceptance-evidence-audit-${{ github.sha }}' "$ci_workflow" || {
  printf 'CI artifact name does not identify committed historical evidence\n' >&2
  exit 1
}
required_count=$(grep -Fc -- '            tests/acceptance/validate-persistence.py' "$ci_workflow")
if (( required_count != 1 )); then
  printf 'validate-persistence.py must appear exactly once in the required harness inputs (found %d)\n' "$required_count" >&2
  exit 1
fi
grep -Fq -- 'sudo apt-get install --yes tesseract-ocr' "$ci_workflow" || {
  printf 'CI does not install the fail-closed screenshot OCR dependency\n' >&2
  exit 1
}
grep -Fq -- 'python3 tests/acceptance/test_audit_screenshots.py' "$ci_workflow" || {
  printf 'CI does not run the screenshot-audit regression suite\n' >&2
  exit 1
}

printf 'browser update workflow dependency and outcome contract passed\n'
