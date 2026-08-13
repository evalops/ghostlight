# Third-Party Notices

This file records external components used by the Ghostlight alpha implementation. Ghostlight publishes a modified Neko Chromium image. The macOS client has no third-party Swift package dependency.

The license names below describe the upstream source or tool. A release must verify the exact version, image digest, binary distribution, and transitive notices used by that release.

| Dependency | Intended use | License | Canonical source |
| --- | --- | --- | --- |
| Neko 3.1.5 | Linux viewer server and web client. Ghostlight rebuilds `/usr/bin/neko` from commit `395ca1a6f62b7b0e270e654d366a2d57b8042efd` with the dependency patch in `viewer/neko-go-modules.patch`. The image contains `/usr/share/doc/neko/LICENSE` and source provenance. | Apache-2.0. Upstream has no `NOTICE` file. | [Neko source](https://github.com/m1k1o/neko/tree/395ca1a6f62b7b0e270e654d366a2d57b8042efd), [`viewer/Dockerfile`](viewer/Dockerfile), [`viewer/neko-go-modules.patch`](viewer/neko-go-modules.patch) |
| Chromium | Linux browser process with a persistent profile. | BSD-3-Clause source license; Chromium distributions include additional third-party notices. | [Chromium LICENSE](https://chromium.googlesource.com/chromium/src/+/main/LICENSE) |
| `golang.org/x/crypto` 0.53.0, `x/net` 0.56.0, `x/sys` 0.46.0, and `x/text` 0.39.0 | Patched Neko server dependencies. | BSD-3-Clause. | [`x/crypto` LICENSE](https://go.googlesource.com/crypto/+/refs/tags/v0.53.0/LICENSE), [`x/net` LICENSE](https://go.googlesource.com/net/+/refs/tags/v0.56.0/LICENSE), [`x/sys` LICENSE](https://go.googlesource.com/sys/+/refs/tags/v0.46.0/LICENSE), [`x/text` LICENSE](https://go.googlesource.com/text/+/refs/tags/v0.39.0/LICENSE) |
| WebRTC | Browser-stream transport between the Linux runtime and macOS client. | BSD-3-Clause source license with a separate patent grant and third-party notice set. | [WebRTC LICENSE](https://webrtc.googlesource.com/src/+/main/LICENSE), [WebRTC native-code license page](https://webrtc.org/support/license) |
| Docker Compose CLI | Local orchestration for the Docker-based Linux runtime. | Apache-2.0. | [Docker Compose LICENSE](https://github.com/docker/compose/blob/main/LICENSE) |
| Go toolchain and standard library | Control service build and test execution. | BSD-style license described by the upstream `LICENSE` file. | [Go LICENSE](https://go.googlesource.com/go/+/master/LICENSE) |
| `modernc.org/sqlite` 1.56.0 | Pure-Go SQLite driver for the durable control catalog. | BSD-3-Clause. | [modernc.org/sqlite source](https://gitlab.com/cznic/sqlite/-/tree/v1.56.0) |
| Playwright | Test-only browser automation for synthetic persistence and performance lanes. | Apache-2.0. | [Playwright LICENSE](https://github.com/microsoft/playwright/blob/main/LICENSE) |
| Tesseract OCR | Test-only rendered-pixel screening for public screenshot receipts. | Apache-2.0. | [Tesseract LICENSE](https://github.com/tesseract-ocr/tesseract/blob/main/LICENSE) |
| Trivy | Test-only image vulnerability scanner in the scheduled browser-update lane. | Apache-2.0. | [Trivy LICENSE](https://github.com/aquasecurity/trivy/blob/main/LICENSE) |

## Verification queue

- Retain the Chromium and Debian package copyright files from the upstream image when publishing a derived viewer image.
- Record the exact WebRTC source revision or client package, including `LICENSE`, `LICENSE_THIRD_PARTY`, `PATENTS`, and any package-specific notices.
- Record the exact Docker Compose CLI version used to validate and run each released runtime configuration.
- When `control/go.mod` adds another non-standard module dependency, enumerate it and add its license and canonical source before distributing the control service.
- When the macOS package or Xcode project selects a third-party Swift or WebRTC package, add that package and its license before distributing the client.

No license is inferred for a dependency that is absent from the repository and not named in the table. The verification queue records the points where an implementation decision must add a source-backed notice.
