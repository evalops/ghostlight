# Ghostlight macOS client

`GhostlightApp` is the native SwiftUI shell for macOS 14 and later. It resumes or creates the durable browser session, renders its tabs and navigation controls, acquires the exclusive controller lease, and embeds the session's WebRTC viewer in `WKWebView`.

## Build and run

```sh
macos/package-app.sh
open macos/.build/Ghostlight.app
```

The packaging script performs a release Swift build, creates `macos/.build/Ghostlight.app`, copies the executable and `Info.plist`, and applies an ad-hoc signature when `codesign` is available. The bundle identifier is `org.evalops.Ghostlight`. The output has no Developer ID signature or notarization receipt.

For the distributable universal ZIP:

```sh
macos/package-release.sh dist
shasum -a 256 --check dist/SHA256SUMS
```

The release script refuses tracked source changes, cross-builds arm64 and x86_64 executables with a macOS 14 deployment target, combines them with `lipo`, and signs the app. It applies an ad-hoc signature by default; when `GHOSTLIGHT_SIGNING_IDENTITY` and the `APPLE_*` notarization credentials are set (as the release workflow does when the repository secrets are configured), it signs with that Developer ID identity, notarizes with `notarytool`, and staples the ticket. It writes `Ghostlight-<version>-macos-universal.zip`, `BUILD-INFO.txt`, and `SHA256SUMS`. The build receipt records the source revision, Swift toolchain, architectures, signing state, and archive digest. A `v<version>` Git tag publishes those files through `.github/workflows/release.yml` after the tag matches `CFBundleShortVersionString`.

The app uses SwiftUI, WebKit, Foundation, and `URLSession`. `Package.swift` declares no third-party Swift package dependency.

## Native session connection

Enter the control service origin and `GHOSTLIGHT_API_TOKEN`, then select **Open Ghostlight**. The client authenticates to the workspace/session API, resumes its saved session when possible, creates a stream descriptor, and attempts to acquire the controller lease. The API token is held only in process memory and is never written to `UserDefaults`.

The control and stream URLs must use HTTP or HTTPS, include a host, and contain no embedded username or password. Server, validation, timeout, network, transport, and decoding failures remain distinct user-visible errors.

After the stream connects, the native Home view provides web search, app shortcuts, open tabs, file attachment, and connection settings. Home shortcuts and searches submit the same revision-fenced browser commands as the toolbar. **Show current page** returns to the live WebRTC viewer without disconnecting it.

Home separates continuity by operation. **Resume** restores a Ghostlight Space. **Browse** reads Chrome-owned bookmarks and Reading List snapshots. **Send** lists destinations explicitly sent from Chrome. Selecting a Browse or Send item creates an expiring, lease-protected intent and resolves a Chrome inbox item only after its command applies. **Dismiss** resolves the item without changing Chromium. **Connect your Chrome** creates the one-use pairing capability described in [Chrome continuity](../docs/chrome-sync.md).

The app registers `ghostlight://send?url=<encoded-http-or-https-url>`. URL handling rejects embedded credentials, fragments, and credential-bearing query keys before submitting the destination with `url_handler` provenance.

## Saved connection

The client stores the control origin and durable session ID in `UserDefaults` after connection succeeds. `GHOSTLIGHT_CONTROL_URL` overrides the saved origin and `GHOSTLIGHT_API_TOKEN` supplies the memory-only token for unattended launch.

Resetting the session cancels event and lease tasks and removes the saved session ID. Lease secrets are never persisted.

## Viewer state

| State | Trigger | UI result |
| --- | --- | --- |
| Connecting | **Open Ghostlight** or automatic launch | Resume/create session, stream, and lease requests run. |
| Controller | Lease acquired and unexpired | Native tab, navigation, attachment, and address controls are enabled. |
| Observer | Another client owns the lease | Stream and session updates remain visible; mutation controls are disabled. |
| Page ready | WebKit finishes the same-origin viewer navigation | The shell waits for causal media readiness. |
| Media ready | Connected peer plus decoded video frame | The loading surface clears and the live browser is authoritative. |
| Failed | Control or WebKit reports a terminal error | The shell shows an actionable failure state. |

`Media ready` is intentionally stronger than document load: an injected observer requires a connected `RTCPeerConnection` and a decoded video frame before removing the loading surface. WebKit cancellation errors from superseded navigation remain ignored.

The web view permits back and forward navigation gestures. Its network and web-content allowances come from `NSAllowsLocalNetworking` and `NSAllowsArbitraryLoadsInWebContent` in `Info.plist`.

## Test

```sh
swift test --package-path macos
macos/package-app.sh
```

The tests cover the control payload contract, API and lease authentication separation, idempotency and revision fences, 204 event polling, settings migration, memory-only secrets, monotonic session updates, focused address editing, lease gating, and causal media readiness.

The Swift tests use URL stubs. They do not authenticate to Neko, negotiate a real WebRTC stream, or inspect restored Chromium state.
