# Ghostlight control API

The control service exposes process liveness, viewer-backed readiness, and stateless viewer discovery. It does not create session identifiers, write a catalog, start Neko, or proxy browser media. Docker Compose owns the viewer and control process lifecycles.

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

Startup applies the same validation to the viewer URL and an explicit health URL. It rejects a missing viewer URL, a relative URL, a URL without a host, a scheme other than HTTP or HTTPS, embedded credentials, and a fragment. The configured discovery URL is returned by `GET /v1/viewer`.

## HTTP API

| Request | Success | Check performed |
| --- | --- | --- |
| `GET /healthz` | `200 {"status":"ok"}` | The Go handler can answer the request. |
| `GET /readyz` | `200 {"status":"ok","viewer":"ready"}` | The viewer returns a `2xx` response from `/health` within the two-second client timeout. |
| `GET /v1/viewer` | `200 {"viewer_url":"<configured-url>"}` | The configured value is available in process memory. |

Readiness replaces the selected health base URL's path and query with `/health`. For example, `http://viewer:8080/login?next=1` produces the readiness target `http://viewer:8080/health`.

Viewer network failure, timeout, redirect, or a response outside `200` through `299` makes `GET /readyz` return `503`. The readiness client does not follow redirects.

```json
{"error":{"code":"viewer_unavailable","message":"configured viewer health check failed"}}
```

Unknown paths return `404`. A known path with a method other than `GET` returns `405`, an `Allow: GET` header, and a JSON error body. The service does not read request bodies.

`GET /v1/viewer` computes the same response from configuration on each request. It performs no write and allocates no session-specific state.

## Network boundary

The service has no authentication, authorization, rate limit, or TLS termination. Compose publishes it on the host address from `GHOSTLIGHT_BIND_ADDRESS`. Keep that address on a loopback or trusted private interface and apply host firewall rules to port `8080/tcp`.

## Container

The multi-stage container build pins the Go and Alpine base images by digest. The final image runs as the unprivileged `ghostlight` user and contains `wget` for its `/readyz` healthcheck. Compose mounts no control data volume.

On `SIGINT` or `SIGTERM`, the process gives active HTTP requests up to five seconds to finish. A shutdown timeout triggers a forced server close and a process error.
