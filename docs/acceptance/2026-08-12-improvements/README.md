# Improvement acceptance status

Date: 2026-08-12

## Reproducible lanes

`tests/acceptance/run-linux-persistence.sh` creates an isolated Compose project,
uses a fresh mode-0700 Chromium profile, serves two privacy-safe loopback pages,
sets cookie and local-storage markers, recreates both containers, and requires
the two tabs and markers to return. Test-only CDP is bound to host loopback.
Screenshots are audited for PNG metadata and obvious secret/address markers.

`tools/test-macos-relaunch.sh` packages no behavior of its own: it launches the
provided Ghostlight app with a control URL, requires the macOS Accessibility
tree to report `Viewer loaded`, quits, relaunches with
`GHOSTLIGHT_CONTROL_URL` explicitly removed, requires the same semantic state,
and captures audited screenshots.

`tools/collect-performance.sh` samples WebRTC stats and container CPU/memory.
Its 2026-08-12 VP8 result is committed under `docs/performance`.

## Executed status

- **Linux persistence: blocked on this nested test host.** Compose booted the
  isolated digest-pinned viewer and test pages were reachable, but Chromium
  151 did not complete target-scoped CDP commands through the committed TCP
  proxy. The lane failed closed before producing or publishing screenshots.
  The final raw failure is in `linux-persistence/transcript.txt`. An earlier
  repository receipt under `docs/acceptance/2026-08-12` remains the live proof,
  but it used uncommitted instrumentation and is not misrepresented as a run of
  this new harness.
- **macOS relaunch: blocked.** The app bundle built and launched, but the
  terminal runner did not receive the macOS Accessibility response required
  for the semantic `Viewer loaded` assertion. The lane failed closed and did
  not publish screenshots. `macos-relaunch/transcript.txt` records only bundle
  provenance; it is not a passing receipt.
- **Performance: passed.** The VP8 receipt observed live inbound media, 251
  decoded frames, zero dropped frames, bitrate, latency, CPU, and memory.

These lanes do not exercise Gmail or make any claim about seven-day daily-driver
acceptance. Synthetic pages are deliberate so receipts contain no account data.
