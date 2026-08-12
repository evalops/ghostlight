# Ghostlight macOS client

`GhostlightApp` is a SwiftUI client for macOS 14 and later. It discovers the configured Neko viewer with `GET /v1/viewer` and loads that URL in an embedded `WKWebView`.

## Build and run

```sh
macos/package-app.sh
open macos/.build/Ghostlight.app
```

The packaging script performs a release Swift build, creates `macos/.build/Ghostlight.app`, copies the executable and `Info.plist`, and applies an ad-hoc signature when `codesign` is available. The bundle identifier is `org.evalops.Ghostlight`. The output has no Developer ID signature or notarization receipt.

The app uses SwiftUI, WebKit, Foundation, and `URLSession`. `Package.swift` declares no third-party Swift package dependency.

## Viewer discovery

The connection field defaults to `http://localhost:8080`. Enter the control service origin and select **Connect**. The client appends `/v1/viewer`, sends a bodyless `GET` request with `Accept: application/json`, accepts an HTTP `2xx` response, and decodes this shape:

```json
{"viewer_url":"http://<linux-host>:8081"}
```

The control and viewer URLs must use HTTP or HTTPS, include a host, and contain no embedded username or password. Use an origin without a path for the shipped control service because its route is exactly `/v1/viewer`.

Server error responses, URL validation errors, timeouts, offline-network errors, other transport errors, malformed HTTP responses, invalid JSON, and unsupported viewer URLs map to separate client errors. A server JSON error message appears with its HTTP status when decoding succeeds.

## Saved connection

The client stores the control URL in `UserDefaults` after viewer discovery succeeds. On a later launch, that URL triggers automatic discovery. `GHOSTLIGHT_CONTROL_URL` overrides the saved value and also triggers automatic discovery for that launch.

**Disconnect** cancels the in-flight discovery task, removes the saved URL, resets viewer retry state, and prevents saved-URL connection on the next launch.

## Viewer state

| State | Trigger | UI result |
| --- | --- | --- |
| Control discovery | **Connect** or automatic launch | Connection form shows progress. |
| Viewer loading | Discovery returns a valid viewer URL or WebKit starts navigation | Embedded viewer and `Loading viewer` status. |
| Viewer loaded | `WKNavigationDelegate` reports navigation completion | `Viewer loaded` status. |
| Viewer failed | WebKit reports provisional or committed navigation failure, or its web-content process terminates | Error status and **Retry** button. |
| Control failed | Discovery validation, transport, HTTP, or decoding failure | Connection form shows the mapped error. |

`Viewer loaded` reports WebKit navigation completion. The client does not inspect Neko's authenticated session, ICE state, decoded frames, or WebRTC connection state.

Automatic discovery from a saved or environment URL retries viewer navigation twice after the first reported failure. A third failure leaves the app in `Viewer failed`. A manual **Connect** does not start that automatic retry loop. **Retry** performs one user-requested load and returns to `Viewer failed` after another reported failure. **Reload** loads the discovered viewer entry URL again after a successful navigation. WebKit cancellation errors from superseded navigation are ignored.

The web view permits back and forward navigation gestures. Its network and web-content allowances come from `NSAllowsLocalNetworking` and `NSAllowsArbitraryLoadsInWebContent` in `Info.plist`.

## Test

```sh
swift test --package-path macos
macos/package-app.sh
```

The tests cover bodyless discovery requests, URL and response validation, HTTP and transport error mapping, saved and environment URL precedence, navigation state transitions, the two-retry limit, explicit retry behavior, redirect handling, disconnect cancellation, and saved-URL removal.

The Swift tests use URL and discovery stubs. They do not launch `Ghostlight.app`, authenticate to Neko, negotiate WebRTC, or inspect restored Chromium state.
