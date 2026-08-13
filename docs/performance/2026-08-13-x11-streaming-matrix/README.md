# X11-driven streaming performance matrix

## Verdict

No candidate is accepted. The direct-LAN control and every complete candidate
used the macOS Playwright WebRTC client as the pixel and stats observer, while
Chromium navigation, scrolling, typing, and F8 markers were driven through
X11 with `xdotool`. CDP diagnostics were disabled and did not gate any run.

All exact-head direct runs used source
`ee58514c20493e1b93fc85677850726c30ce51c4`, the digest-pinned public viewer
image, four 10-second phase windows after 3-second warmups, and a selected UDP
candidate pair in every phase. The temporary firewall rules admitted only
`192.168.4.103` on `eth0` to the exact viewer TCP and WebRTC UDP ports; each
run's trap deleted both rules, and the final UFW listing contained none of the
benchmark ports.

## Results

| Run | Median CPU | CPU change | Input p95 | Decoded fps | Dropped | Freeze | Marker | Verdict |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| Control 1, 1920x1080 at 25 fps | 122.605% | - | 298.680 ms | 25.024 | 0 | 0 | 100% | valid |
| 1600x900 pair 1 | 100.183% | -18.29% | 228.775 ms | 25.016 | 0 | 0.02778 | 100% | reject: freeze regression |
| Control 2, 1920x1080 at 25 fps | 116.798% | - | 239.180 ms | 25.018 | 0 | 0 | 100% | valid |
| 1600x900 pair 2 | 93.135% | -20.26% | 236.480 ms | 25.014 | 0 | 0 | 100% | quality gates pass |
| Control 3, 1920x1080 at 25 fps | 128.733% | - | 1258.955 ms | 24.352 | 0.02761 | 0.00862 | 100% | valid but degraded |
| 1600x900 pair 3 | 95.785% | -25.59% | 247.710 ms | 25.014 | 0 | 0 | 100% | quality gates pass |
| 1920x1080 at 20 fps, vs control 2 | 105.790% | -9.42% | 389.080 ms | 19.973 | 0 | 0 | 100% | reject: 1.627x latency |
| VP8 `cpu-used=8`, vs control 2 | 118.825% | +1.74% | 229.975 ms | 24.999 | 0 | 0.025 | 100% | reject: CPU and freeze |
| `use-damage=true`, vs control 2 | 120.755% | +3.39% | 231.640 ms | 24.962 | 0 | 0.00735 | 100% | reject: CPU and freeze |

The 1600x900 CPU reduction appeared in all three pairs, but only two of three
candidates passed every paired quality gate. It is therefore rejected
rather than promoted. The 20 fps and VP8 encoder candidates also failed their
paired gates. The first `use-damage` attempt failed closed when the local disk
filled; the table reports its complete bounded rerun.

The exact pinned viewer image exposes none of `x264enc`, `openh264enc`,
`vah264enc`, or `vaapih264enc`, and the host does not expose
`/dev/dri/renderD128` to the container. H.264 and VAAPI therefore require a
separate image or stack change and were not claimed by this matrix.

## Raw receipt manifest

The raw receipt directories are retained in the continuation workspace. SHA-256
binds each receipt named below:

| Receipt directory | `receipt.json` SHA-256 |
| --- | --- |
| `ssh-smoke3-cba102d` | `aa0c2b44795d0adf7534d838ed18b01d6254746b607459356b63f9ab2f93f349` |
| `stable-control1-ee58514` | `d85960a02a8fcc852a6db18ec0b69f68d735f0662ff70c5e5c62864b3806cc56` |
| `stable-1600-1-ee58514` | `5bb2e54bad8f474ff4e317e7c25d18b63781f1ea3b28aa5e7c09e1ecaac003bf` |
| `stable-control2-ee58514` | `cd1e13ac12abf0b5f052519cb692fdc23cea6d7a1f13361fba6bf267d30d93d2` |
| `stable-1600-2-ee58514` | `830abc9fa74cdf8c75fe26c8fb16222436cd06393ecd357e9ee7b88044463db9` |
| `stable-control3-ee58514` | `f30cca7a00093cb01fad769ac1b6db31a2d881f16b9798fb1cb78a776cafbaba` |
| `stable-1600-3-ee58514` | `1c3dc25cf135fe2471c7544470934651649221eb0a49b7b7a8d819f610654b27` |
| `stable-20fps-ee58514` | `1ae55613aaa8ef2a15c84803b13fb26ef81358b4f5dc95c09562b8d9fc06a863` |
| `stable-cpu8-ee58514` | `7bd93f6823d53448492cee472265bfe280ac2c3999109f0ba9b5188310f6ba97` |
| `stable-use-damage-ee58514` | `a4c14336eb2df6eef67f8af42bb026ef5ba25638cb89352948407f4aef9c4bf1` |

The SSH smoke is a complete four-phase receipt from source
`cba102da5b0772f6e1daae0a921ab26fb05926bd`. It negotiated VP8 over TCP through
the SSH tunnel, observed 100% causal markers, and is not used as a direct-UDP
performance control.

## Environment blocker

The macOS APFS volume reached 100% utilization during the matrix. A long-lived
Virtualization VM process held about 2.96 GiB of already-deleted files open.
Generated Ghostlight caches and incomplete benchmark output were removed. The
external process later released its files, and the invalid `use-damage` run was
repeated from the same exact source. No VM was terminated because it was outside
this branch's ownership.
