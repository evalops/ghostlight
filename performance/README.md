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

The baseline decision is superseded: the runtime default is now H.264 (constrained baseline, 3072 kbps, zero-latency x264 via `NEKO_CAPTURE_VIDEO_CODEC` and `NEKO_CAPTURE_VIDEO_PIPELINE` in `runtime/.env`), negotiated as `profile-level-id=42e01f`. The native macOS receipt still reports navigation state only and does not claim decoded WebRTC frames, CPU, or memory, so the power-efficiency question this change bets on remains unproven on the Mac client.

The outstanding receipt is paired: one H.264 run against the stock stack and one VP8 control run, each through `tools/collect-performance.sh`, plus a native WKWebView decode capture. `tests/acceptance/performance.mjs` supports `GHOSTLIGHT_PERFORMANCE_CODEC=default|h264`, which only reorders the Playwright client's `setCodecPreferences`; the runtime picks the actual codec. Capture the pair from a clean tree:

```sh
# H.264 run: stock stack (runtime default is H.264), explicit client preference.
GHOSTLIGHT_PERFORMANCE_VIEWER_URL=http://<linux-host>:8081 \
GHOSTLIGHT_PERFORMANCE_VIEWER_CONTAINER=<viewer-container-id> \
GHOSTLIGHT_PERFORMANCE_NEKO_PASSWORD=<synthetic-or-test-password> \
GHOSTLIGHT_PERFORMANCE_CODEC=h264 \
GHOSTLIGHT_PERFORMANCE_OUTPUT_DIR=output/playwright/performance/h264 \
tools/collect-performance.sh
```

```sh
# VP8 control run: set NEKO_CAPTURE_VIDEO_CODEC=vp8 and an empty
# NEKO_CAPTURE_VIDEO_PIPELINE in runtime/.env, recreate the stack, then:
GHOSTLIGHT_PERFORMANCE_VIEWER_URL=http://<linux-host>:8081 \
GHOSTLIGHT_PERFORMANCE_VIEWER_CONTAINER=<viewer-container-id> \
GHOSTLIGHT_PERFORMANCE_NEKO_PASSWORD=<synthetic-or-test-password> \
GHOSTLIGHT_PERFORMANCE_CODEC=default \
GHOSTLIGHT_PERFORMANCE_OUTPUT_DIR=output/playwright/performance/vp8 \
tools/collect-performance.sh
```

Confirm `codec.mimeType` and `codec.sdpFmtpLine` in each `webrtc.json` match the intended codec before comparing decoded frames, bitrate, and the `container-stats.jsonl` CPU and memory samples. For the native half, connect the Mac client to the H.264 stack and record whether decode uses the power-efficient VideoToolbox path, the per-frame decode time, and the client CPU; no script in this repository captures that yet.
