# Streaming performance harness

`tests/acceptance/performance.mjs` drives the Neko UI with Playwright, observes the WebRTC inbound-video stats, and records the dispatch-to-next-presented-frame phase, decoded and dropped frames, bytes received, bitrate, codec, and decoder details. The phase ends at the next presented frame but does not prove that the synthetic key event caused that frame, so it is not an input-latency measurement. `tools/collect-performance.sh` samples the viewer container's CPU and memory alongside that browser receipt and writes timestamped JSON plus SHA-256 sidecars.

Run the live Linux/browser measurement with the synthetic acceptance viewer:

```sh
GHOSTLIGHT_PERFORMANCE_VIEWER_URL=http://<linux-host>:8081 \
GHOSTLIGHT_PERFORMANCE_VIEWER_CONTAINER=<viewer-container-id> \
GHOSTLIGHT_PERFORMANCE_NEKO_PASSWORD=<synthetic-or-test-password> \
tools/collect-performance.sh
```

The collector refuses a dirty source tree or a viewer image without a digest-pinned reference. A future exact-source measurement records the source SHA and clean-tree state, viewer container ID, image reference and immutable image ID, acceptance lockfile hash, runtime versions, duration, and redacted test endpoint.

The committed 2026-08-12 VP8 baseline records `source_sha=working-tree-20260812T1720Z`. It remains a measurement and is not an exact-source receipt.

```sh
shasum -a 256 output/playwright/performance/*.json \
  output/playwright/performance/*.jsonl
```

The runtime default is H.264 constrained baseline at 3072 kbps. The
[current-main codec receipt](../docs/performance/2026-08-13-h264-vp8-current-main/README.md)
contains three alternating VP8/H.264 pairs on direct UDP. H.264 reduced median
viewer CPU by 48.22% and native Mac CPU by 27.18%. The experiment is rejected
because two VP8 controls recorded freezes and both browsers
omitted the optional `powerEfficientDecoder` statistic.

`tools/run-current-main-codec-pair.sh` runs the six-run receipt from a clean
checkout whose HEAD equals `github/main`. It drives the synthetic fixture
through X11 and records macOS Playwright plus Ghostlight.app WKWebView evidence.
