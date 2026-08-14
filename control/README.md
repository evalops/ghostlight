# Ghostlight control API

The control service exposes process liveness, viewer-and-storage readiness, legacy viewer discovery, and durable browser product resources. It owns one workspace and one durable browser session, controller leases, tab snapshots, a bounded command queue, stream descriptors, and attachment metadata. Docker Compose still owns the viewer and control process lifecycles, and control never proxies browser media.

## Commands

```sh
make test
make test-race
make build
```

`make build` produces `control/ghostlight-control` with `CGO_ENABLED=0`.

## Configuration

| Variable | Required | Default | Description |
| --- | --- | --- | --- |
| `GHOSTLIGHT_VIEWER_URL` | yes | none | Absolute HTTP or HTTPS URL returned by viewer discovery and used to derive the readiness URL. |
| `GHOSTLIGHT_VIEWER_HEALTH_URL` | no | `GHOSTLIGHT_VIEWER_URL` | Absolute HTTP or HTTPS base URL used only for readiness. Compose can set this to the internal viewer service address. |
| `GHOSTLIGHT_LISTEN_ADDR` | no | `:8080` | TCP address passed to `net.Listen`. |
| `GHOSTLIGHT_STATE_DIR` | yes | none | Private directory containing the SQLite catalog. |
| `GHOSTLIGHT_ATTACHMENT_DIR` | yes | none | Private directory containing staged attachment bodies. |
| `GHOSTLIGHT_API_TOKEN` | yes | none | Bearer token for workspace and session routes. |
| `GHOSTLIGHT_BRIDGE_TOKEN` | yes | none | Separate bearer token for the Chromium bridge routes. |
| `GHOSTLIGHT_VIEWER_PASSWORD` | yes | none | Neko member password released only after an atomic, scoped viewer-capability redemption. Compose sources it from `NEKO_USER_PASSWORD`. |
| `GHOSTLIGHT_LEASE_TTL_SECONDS` | no | `30` | Controller lease lifetime from 1 through 3600 seconds. |

Startup applies the same validation to the viewer URL and an explicit health URL. It rejects a missing viewer URL, a relative URL, a URL without a host, a scheme other than HTTP or HTTPS, embedded credentials, and a fragment. The configured discovery URL is returned by `GET /v1/viewer`.

## HTTP API

| Request | Success | Check performed |
| --- | --- | --- |
| `GET /healthz` | `200 {"status":"ok"}` | The Go handler can answer the request. |
| `GET /readyz` | `200 {"status":"ok","viewer":"ready"}` | The viewer returns a `2xx` response from `/health` within the two-second client timeout. |
| `GET /v1/viewer` | `200 {"viewer_url":"<configured-url>"}` | The configured value is available in process memory. |
| `GET /v1/workspaces` | `200` | Returns the durable workspace catalog. |
| `GET, POST /v1/workspaces/{id}/spaces` | `200`, `201` | Lists Spaces or captures the current safe HTTP/HTTPS tab destinations under a lease and revision fence. |
| `POST /v1/workspaces/{id}/spaces/{space}/park` | `200` | Refreshes a Space from the authoritative browser snapshot and marks it parked. |
| `POST /v1/workspaces/{id}/spaces/{space}/activate` | `202` | Queues an idempotent browser-extension restore; the Space becomes active only after an applied command receipt. |
| `GET, POST /v1/sessions` | `200` | Lists or idempotently ensures the single durable browser session. |
| `GET /v1/sessions/{id}` | `200` | Returns authoritative session, tab, lease, and stream state. |
| `GET /v1/sessions/{id}/events` | `200, 204` | Returns a newer revision or no content. |
| `POST, PUT, DELETE /v1/sessions/{id}/leases[/{lease}]` | `201, 200, 204` | Acquires, renews, or releases the exclusive controller lease. |
| `POST /v1/sessions/{id}/commands` | `202` | Queues an idempotent, revision-fenced browser command. |
| `GET /v1/sessions/{id}/commands/{command}` | `200` | Returns queued or durable terminal command status and result. |
| `POST /v1/sessions/{id}/stream` | `201` | Creates a short-lived descriptor for the current Neko stream. |
| `GET, POST /v1/sessions/{id}/attachments` | `200, 201` | Lists metadata or stages a lease-authorized file up to 25 MiB. A session is capped at 100 files and 1 GiB. |
| `POST /v1/workspaces/{id}/chrome-pairings` | `201` | Creates a one-use, 10-minute Chrome pairing capability. |
| `POST /v1/chrome-pairings/redeem` | `201` | Exchanges that capability for a hashed, write-only device credential. |
| `POST /v1/chrome-handoffs` | `201` | Accepts one idempotent safe-URL handoff from a paired Chrome device. |
| `GET, PUT /v1/workspaces/{id}/chrome-handoffs[/{handoff}]` | `200` | Lists pending handoffs or marks one opened/dismissed. |
| `GET, DELETE /v1/workspaces/{id}/chrome-devices[/{device}]` | `200, 204` | Lists paired devices or revokes one. |

Readiness replaces the selected health base URL's path and query with `/health`. For example, `http://viewer:8080/login?next=1` produces the readiness target `http://viewer:8080/health`.

Viewer network failure, timeout, redirect, or a response outside `200` through `299` makes `GET /readyz` return `503`. The readiness client does not follow redirects.

```json
{"error":{"code":"viewer_unavailable","message":"configured viewer health check failed"}}
```

Unknown paths return `404`. A known path with a method other than `GET` returns `405`, an `Allow: GET` header, and a JSON error body. The service does not read request bodies.

`GET /v1/viewer` remains a stateless compatibility route. Product routes require the API bearer token. Lease renewal, release, commands, and attachment upload also require the lease token returned only when a client acquires a lease. Bridge routes use the separate bridge bearer token. Chrome pairing redemption uses a one-time capability; handoff writes use the resulting `handoff:write` device credential. Request bodies reject unknown JSON fields; session ensure, command, and Chrome handoff requests require `Idempotency-Key`. The bridge records command completion before acknowledging it, and control retains terminal status so a lost response retries the acknowledgment without replaying the browser action.

Spaces contain names, ordered credential-free HTTP/HTTPS destinations, active position, Home preference ownership, and opaque pending-handoff IDs. They do not contain titles, page content, cookies, credentials, history, incognito state, or Chromium profile data. Restores run through the extension command path and become authoritative only after the command is applied.

## Network boundary

The service has bearer authentication and lease fencing but no rate limit or TLS termination. Compose publishes it on the host address from `GHOSTLIGHT_BIND_ADDRESS`. Keep that address on a loopback or trusted private interface and apply host firewall rules to port `8080/tcp`.

## Container

The multi-stage container build pins the Go and Alpine base images by digest. The final image runs as the unprivileged `ghostlight` user and contains `wget` for its `/readyz` healthcheck. Compose mounts separate named volumes for the mode-`600` SQLite database and attachment bodies; their directories are mode `700`.

On `SIGINT` or `SIGTERM`, the process gives active HTTP requests up to five seconds to finish. A shutdown timeout triggers a forced server close and a process error.
