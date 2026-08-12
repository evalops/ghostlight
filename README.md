# Ghostlight

Ghostlight runs a persistent Chromium profile on Linux and streams the browser to a native macOS client over WebRTC.

The first alpha targets one user, one browser session, direct LAN connectivity, and a Docker-based Linux runtime.

## Repository layout

- `macos/`: native Swift client
- `control/`: session control API
- `runtime/`: browser-streaming containers and configuration
- `docs/`: architecture and test notes
- `scripts/`: integration and smoke-test scripts

## Status

Initial implementation is in progress.
