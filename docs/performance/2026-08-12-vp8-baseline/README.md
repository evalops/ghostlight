# VP8 WebRTC performance receipt

Captured on 2026-08-12 against the digest-pinned Neko Chromium stack on a
developer-managed Linux host. The endpoint is represented by a SHA-256 digest
in the artifacts; credentials and the endpoint itself were not recorded.

## Result

| Measure | Result |
| --- | ---: |
| Sample | 10.08 s |
| Browser input dispatch to presented video frame | 72.43 ms |
| Decoded frames | 251 |
| Dropped frames | 0 |
| Received bitrate | 1.17 Mbps |
| Negotiated codec | VP8 |
| Sampled viewer CPU | 3.62% to 85.63% |
| Sampled viewer memory | 272.4 MiB to 376 MiB |

The latency receipt starts immediately before synthetic keyboard dispatch and
ends at the next presented WebRTC video-frame callback. It includes browser
dispatch, network, decode, and presentation scheduling, but does not include a
physical keyboard poll or display scanout. It is therefore repeatable and
useful for comparisons, but is not a camera-measured human input-to-photon
number.

The browser advertised H.264 receive support. No paired H.264 run or native
WKWebView evidence was completed, so this receipt supports retaining Neko's
pinned default VP8 pipeline. It does not support changing the runtime default.

Artifacts:

- `webrtc.json`: decoded/dropped frames, bytes, bitrate, codec, and latency.
- `container-stats.jsonl`: repeated raw `docker stats` samples.
- `neko-pipeline.log`: server-side pipeline provenance showing the default VP8
  encoder configuration.
- `transcript.txt`: source label, tool versions, endpoint hash, and SHA-256
  hashes for the raw evidence.
