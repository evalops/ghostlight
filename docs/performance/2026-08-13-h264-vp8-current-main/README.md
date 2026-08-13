# Current-main H.264 and VP8 codec pair

## Verdict

The experiment is rejected because two required gates failed. Two of the three
VP8 controls recorded freezes, so `absolute_control_health` failed. WebRTC stats
from Chromium and WKWebView omitted `powerEfficientDecoder`, so
`native_h264_power_efficient_decoder` failed. The WebRTC Stats specification
permits user agents to omit that field when exposing hardware information is
not allowed.

H.264 reduced median viewer CPU by 48.22% in the three-run aggregate. The VP8
median was 126.79%; H.264 was 65.65%. Native Mac CPU fell from 10.30% to 7.50%.
Received bitrate fell from 934.41 kbps to 697.54 kbps. Viewer memory p95 fell
from 606.07 MiB to 556.19 MiB. These measurements do not establish hardware
decoding.

## Method

- Source: `30647ca6597dc1695603b50b5b46ab7a3d88df9c`
- Image: `ghcr.io/evalops/ghostlight-viewer@sha256:5ab745d2fc8972eab3ba2ddcaf109079d8bec45be51b9f9e28f61c3c8ae2ec8c`
- Order: VP8/H.264, H.264/VP8, VP8/H.264
- Workload: 1920x1080, 25 fps, 3072 kbps, four 30-second phases after a 10-second warmup
- Input: Chromium startup URL plus X11 `xdotool` for navigation, scrolling, typing, animation, and F8 markers
- Observer: macOS Playwright for causal pixels and WebRTC stats; Ghostlight.app WKWebView for native decode and process CPU
- Transport: selected candidate pair `udp` in 24 of 24 phases
- CDP: disabled and absent from every gate
- Firewall: 12 temporary rules admitted only `192.168.4.103` on `eth0` to the six isolated TCP/UDP port pairs. The recorded and live post-run UFW files match the pre-run SHA-256.

## Runs

| Pair | Codec | Viewer CPU | Native Mac CPU | Input p95 | Dropped ratio | Freeze ratio | Marker |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | VP8 | 126.79% | 9.20% | 409.34 ms | 0.00104 | 0.02124 | 100% |
| 1 | H.264 | 65.93% | 8.10% | 368.58 ms | 0 | 0 | 100% |
| 2 | H.264 | 64.45% | 6.85% | 410.96 ms | 0 | 0 | 100% |
| 2 | VP8 | 155.64% | 10.30% | 448.88 ms | 0 | 0.08065 | 100% |
| 3 | VP8 | 118.62% | 10.65% | 363.89 ms | 0.00033 | 0 | 100% |
| 3 | H.264 | 65.65% | 7.50% | 396.48 ms | 0 | 0 | 100% |

The aggregate actual-to-target FPS ratio was 0.99985. All H.264 native receipts
recorded zero dropped frames. The aggregate H.264 causal input p95 was 0.969
times the VP8 control; pair 3 was 8.95% slower than its control.

## Receipts

[`aggregate-receipt.json`](aggregate-receipt.json) contains the aggregate
metrics and gate results. [`receipt-manifest.sha256`](receipt-manifest.sha256)
binds the six full server receipts, six native receipts, aggregate output, and
firewall files retained under local directory `output/codec-pair-30647ca/`.

The optional-field rule is defined in the
[W3C WebRTC Stats specification](https://www.w3.org/TR/webrtc-stats/#dom-rtcinboundrtpstreamstats-powerefficientdecoder).
