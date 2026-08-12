# Streaming performance harness

`tests/acceptance/performance.mjs` drives the Neko UI with Playwright, observes the WebRTC inbound-video stats, and records input-to-presented-frame latency, decoded and dropped frames, bytes received, bitrate, codec, and decoder details. `tools/collect-performance.sh` samples the viewer container's CPU and memory alongside that browser receipt and writes timestamped JSON plus SHA-256 sidecars.

Run the live Linux/browser measurement with the synthetic acceptance viewer:

```sh
GHOSTLIGHT_PERFORMANCE_VIEWER_URL=http://<linux-host>:8081 \
GHOSTLIGHT_PERFORMANCE_VIEWER_CONTAINER=<viewer-container-id> \
GHOSTLIGHT_PERFORMANCE_NEKO_PASSWORD=<synthetic-or-test-password> \
tools/collect-performance.sh
```

The scheduled candidate lane runs the persistence harness and image scans. A measurement receipt is only valid when it records the exact source SHA, pinned Neko image, runtime, browser, duration, and redacted test endpoint.

```sh
shasum -a 256 output/playwright/performance/*.json \
  output/playwright/performance/*.jsonl
```

The baseline decision keeps the pinned Neko default VP8 path. H.264 is not selected because this repository has no proven WKWebView decode comparison. The native macOS receipt therefore reports navigation state only and does not claim decoded WebRTC frames, CPU, or memory.
