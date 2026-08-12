# Contributing to Ghostlight

## Scope

The alpha targets one user, one browser session, direct LAN connectivity, and a Docker-based Linux runtime. A change that expands those boundaries needs an architecture update and tests for the new lifecycle.

Before opening a pull request:

1. Read `docs/architecture.md` and confirm that the change preserves the shared ports and API contract or updates all affected components together.
2. Run the checks that apply to the paths you changed.
3. Include the commands and results in the pull request description.
4. List any skipped check and the missing optional path or tool that caused the skip.

## Required checks

Run the following from the repository root:

```sh
bash scripts/check-repo-hygiene.sh
bash scripts/test-repo-hygiene.sh
bash scripts/check-shell.sh
```

Run `go test ./...` from `control/` when `control/go.mod` exists. Run `swift test --package-path macos` or the repository's documented `xcodebuild test` command when `macos/` contains a Swift package or Xcode project. Run `docker compose -f <file> config --quiet` for each Compose file under `runtime/`; this command validates syntax without starting containers.

The CI workflow runs Go tests when `control/go.mod` exists. It runs Swift tests when `macos/` contains a Swift package or Xcode project. It validates Compose files when `runtime/` contains a Compose file. Each detected module must pass its test command.

## Pull requests

Keep a pull request focused on one change. Describe the user-visible or operator-visible result, the files changed, the verification commands, and any remaining risk.

Do not include secrets, cookies, profile archives, private LAN addresses, viewer URLs, or request bodies in commits, logs, screenshots, or pull requests.

Do not merge a pull request while required checks are pending. Do not force-push a shared branch.

## Dependencies and licenses

Add each newly selected dependency to `THIRD_PARTY_NOTICES.md` with its exact version or revision, license, canonical source, and any required notice or patent file. If the license is not confirmed from an upstream source, write `License verification required` and explain the missing evidence in the verification queue.
