# Third-Party Notices

This file records external components named by the Ghostlight alpha design or intended for the first implementation. The repository does not bundle these components at the baseline commit.

The license names below describe the upstream source or tool. A release must verify the exact version, image digest, binary distribution, and transitive notices used by that release.

| Dependency | Intended use | License | Canonical source |
| --- | --- | --- | --- |
| Chromium | Linux browser process with a persistent profile. | BSD-3-Clause source license; Chromium distributions include additional third-party notices. | [Chromium LICENSE](https://chromium.googlesource.com/chromium/src/+/main/LICENSE) |
| WebRTC | Browser-stream transport between the Linux runtime and macOS client. | BSD-3-Clause source license with a separate patent grant and third-party notice set. | [WebRTC LICENSE](https://webrtc.googlesource.com/src/+/main/LICENSE), [WebRTC native-code license page](https://webrtc.org/support/license) |
| Docker Compose CLI | Local orchestration for the Docker-based Linux runtime. | Apache-2.0. | [Docker Compose LICENSE](https://github.com/docker/compose/blob/main/LICENSE) |
| Go toolchain and standard library | Planned control-service implementation and test execution when `control/` is added. | BSD-style license described by the upstream `LICENSE` file. | [Go LICENSE](https://go.googlesource.com/go/+/master/LICENSE) |
| SQLite | Session catalog persistence. | Public domain for the deliverable SQLite code; build scripts and packaged additions require separate verification. | [SQLite copyright and license page](https://www.sqlite.org/copyright.html) |

## Verification queue

- Record the exact Chromium release or container image digest and retain its Chromium license and generated third-party notice output.
- Record the exact WebRTC source revision or client package, including `LICENSE`, `LICENSE_THIRD_PARTY`, `PATENTS`, and any package-specific notices.
- Record the exact Docker Compose CLI version used to validate and run each released runtime configuration.
- When `control/go.mod` exists, enumerate every module dependency and add its license and canonical source before distributing the control service.
- When the macOS package or Xcode project selects a third-party Swift or WebRTC package, add that package and its license before distributing the client.
- Record the exact SQLite release or system library and the selected Go driver after the control implementation chooses them.

No license is inferred for a dependency that is absent from the repository and not named in the table. The verification queue records the points where an implementation decision must add a source-backed notice.
