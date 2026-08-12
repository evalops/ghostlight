# Linux runtime

This directory runs one Chromium browser stream and the Ghostlight control API.

The Compose stack contains two services:

- `viewer` runs `ghcr.io/m1k1o/neko/chromium:3.1.0` and stores the Chromium profile in `runtime/data/chromium`.
- `control` builds from `../control`, stores session records in `runtime/data/control`, and publishes the session API.

The Neko repository is [Apache-2.0 licensed](https://github.com/m1k1o/neko/blob/master/LICENSE). Its documented image source is [GHCR](https://neko.m1k1o.net/docs/v3/installation/docker-images). The runtime pins release `3.1.0`; update the tag deliberately after checking the upstream release and image availability.

## Install

Run these commands on the Linux host that will run Docker:

```sh
cd runtime
cp .env.example .env
```

Edit `.env` before starting the stack:

- Set `NEKO_USER_PASSWORD` and `NEKO_ADMIN_PASSWORD` to different generated values.
- Set `NEKO_WEBRTC_NAT1TO1` to the Linux host address reachable by the client when the host is behind NAT or a routed LAN.
- Set `GHOSTLIGHT_VIEWER_URL` to the same reachable address with port `8081`.

Then run:

```sh
./bin/preflight.sh
docker compose up -d
./bin/smoke.sh
```

`runtime/.env` and `runtime/data/` are ignored by Git. Do not commit passwords, session records, or browser profile files.

## HTTP and WebRTC ports

| Service | Default host port | Protocol | Use |
| --- | ---: | --- | --- |
| Control | `8080` | TCP | Health and session API |
| Viewer | `8081` | TCP | Neko web viewer and WebSocket signaling |
| WebRTC mux | `52000` | UDP and TCP | Audio, video, and input transport |

The Compose file maps `52000` without remapping it inside the container. Allow both `52000/udp` and `52000/tcp` through the Linux host firewall. The Neko documentation states that ICE candidates contain the server address and port, so a different host mapping can make the media path unreachable.

For a deployment that uses an ephemeral UDP range instead of muxing, set `NEKO_WEBRTC_EPR` and map the identical host and container range as UDP. Keep TCP mux enabled when clients may be on networks that block UDP.

## Operational checks

`bin/preflight.sh` validates the Compose model, control source path, data directories, and install-time placeholders. It does not start containers.

`bin/smoke.sh` validates Compose configuration, `GET /healthz`, `POST /v1/sessions`, and the `viewer_url` returned by the control API.

The sibling control service must provide:

- `GET /healthz` with a JSON body containing `{"status":"ok"}`.
- `POST /v1/sessions` with an optional JSON object and a JSON response containing `id`, `viewer_url`, and `created_at`.
