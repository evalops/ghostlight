# Ghostlight

Ghostlight runs a persistent Chromium profile on Linux and streams the browser to a native macOS client over WebRTC.

The alpha targets one user, one Neko browser session, and direct LAN connectivity. The macOS app creates a session record through the Go control API, then loads the Neko viewer in `WKWebView`.

## Requirements

- macOS 14 or later with a Swift 6 toolchain
- a Linux host with Docker Engine, Docker Compose, and Buildx 0.17 or later
- TCP access to the control and viewer ports
- TCP and UDP access to the WebRTC mux port

## Start the Linux runtime

```sh
cp runtime/.env.example runtime/.env
```

Edit `runtime/.env` before starting the containers:

- set `GHOSTLIGHT_VIEWER_URL` to the viewer URL reachable from the Mac
- replace `NEKO_USER_PASSWORD` and `NEKO_ADMIN_PASSWORD` with generated values
- set `NEKO_WEBRTC_NAT1TO1` to the Linux host address advertised to the Mac

Then run:

```sh
runtime/bin/preflight.sh
docker compose --env-file runtime/.env -f runtime/docker-compose.yml up --build -d
runtime/bin/smoke.sh
```

The defaults expose the control API on TCP `8080`, the Neko viewer on TCP `8081`, and the WebRTC mux on TCP and UDP `52000`. Chromium state persists under `runtime/data/chromium`.

## Run the macOS client

```sh
swift run --package-path macos GhostlightApp
```

Enter the Linux control URL, such as `http://192.168.1.20:8080`, and select Connect. Ghostlight creates the session record and opens the returned viewer URL.

## Test

```sh
(cd control && go test ./...)
swift test --package-path macos
runtime/tests/test_runtime.sh
scripts/test-repo-hygiene.sh
bash scripts/check-shell.sh
```

CI runs these module checks on Linux and macOS. It also validates the Compose model and repository license files.

## Repository layout

- `macos/`: native Swift client
- `control/`: session control API
- `runtime/`: browser-streaming containers and configuration
- `docs/`: architecture and test notes
- `scripts/`: integration and smoke-test scripts

The component and trust-boundary details are in [docs/architecture.md](docs/architecture.md). Dependency sources and licenses are recorded in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Alpha limits

- The control API has no authentication and is intended for a trusted test network.
- One Neko container serves every control-plane session record.
- Neko handles viewer login and browser input inside the embedded web client.
- TURN, TLS, multi-host scheduling, account management, billing, and automatic updates are absent.
- The Swift package produces a development executable. Signing and distribution packaging are absent.

Ghostlight is licensed under Apache-2.0.
