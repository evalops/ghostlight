# VP8 WebRTC performance measurement

Captured on 2026-08-12 against the digest-pinned Neko Chromium stack on a
developer-managed Linux host. The endpoint is represented by a SHA-256 digest
in the artifacts; credentials and the endpoint itself were not recorded.

## Result

| Measure | Result |
| --- | ---: |
| Sample | 10.08 s |
| Dispatch to next presented video frame (phase) | 72.43 ms |
| Decoded frames | 251 |
| Dropped frames | 0 |
| Received bitrate | 1.17 Mbps |
| Negotiated codec | VP8 |
| Sampled viewer CPU | 3.62% to 96.01% |
| Sampled viewer memory | 272.4 MiB to 376 MiB |

The phase starts immediately before synthetic keyboard dispatch and ends at the
next presented WebRTC video-frame callback. The harness does not prove that the
key event caused that frame, so 72.43 ms is not an input-latency or
input-to-photon result.

The browser advertised H.264 receive support. No paired H.264 run or native
WKWebView evidence was completed, so this receipt supports retaining Neko's
pinned default VP8 pipeline. It does not support changing the runtime default.

Artifacts:

- `webrtc.json`: decoded/dropped frames, bytes, bitrate, codec, and the
  dispatch-to-next-frame phase. Review normalized the metric names and
  limitations without changing the captured numeric values; `transcript.txt`
  preserves both the captured and normalized artifact hashes.
- `container-stats.jsonl`: repeated raw `docker stats` samples.
- `neko-pipeline.log`: server-side pipeline provenance showing the default VP8
  encoder configuration.
- `transcript.txt`: source label, tool versions, endpoint hash, and SHA-256
  hashes for the raw evidence.

The transcript records `source_sha=working-tree-20260812T1720Z`, not an exact commit SHA. This directory therefore records a working-tree measurement rather than an exact-source receipt.
