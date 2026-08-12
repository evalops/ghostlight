# Ghostlight macOS client

GhostlightApp is a native SwiftUI alpha for macOS 14 and later. It accepts a
control-plane URL, creates one browser session with `POST /v1/sessions`, and
opens the returned `viewer_url` in an embedded `WKWebView`. The embedded web
view remains a native macOS view so browser keyboard input is delivered to the
viewer normally.

## Run

From the repository root:

```sh
macos/package-app.sh
open macos/.build/Ghostlight.app
```

The local bundle is ad-hoc signed with identifier `org.evalops.Ghostlight`; it is not notarized for distribution. The default control-plane URL is `http://localhost:8080`. After a successful connection, Ghostlight saves the URL and reconnects automatically on a later launch.

## Test

```sh
swift test
```

The test suite covers request JSON encoding, `viewer_url` response decoding,
HTTP(S) control-plane URL validation, and transport/HTTP error mapping.

## Dependencies and API shape

There are no third-party Swift dependencies. The client uses Foundation and
`URLSession` for networking, SwiftUI for the app surface, and WebKit for the
viewer.

The create-session request currently sends `{}`. A successful response must
include a URL-valued `viewer_url`, for example:

```json
{"viewer_url":"http://localhost:6080/viewer"}
```
