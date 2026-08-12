# Ghostlight control API

The service stores session metadata and returns the configured viewer URL for each session.

## Requirements and commands

The module requires Go 1.24.

```sh
make test
make test-race
make build
```

`make run` starts the service on `:8080` with a local viewer URL and a store at `./sessions.json`.

## Configuration

| Variable | Required | Default | Description |
| --- | --- | --- | --- |
| `GHOSTLIGHT_VIEWER_URL` | yes | — | Absolute URL with the `http` or `https` scheme. |
| `GHOSTLIGHT_LISTEN_ADDR` | no | `:8080` | TCP address passed to `net.Listen`. |
| `GHOSTLIGHT_STORE_PATH` | no | `/data/sessions.json` | JSON store path. |

The process exits during startup when `GHOSTLIGHT_VIEWER_URL` is missing or invalid.

The alpha API has no authentication layer. Restrict port `8080` to the trusted LAN or an equivalent network boundary before exposing it to untrusted clients.

## HTTP API

`GET /healthz` returns `200` and `{"status":"ok"}`.

`POST /v1/sessions` accepts an empty body or one JSON object with `Content-Type: application/json`. The object is reserved for future session options; its fields are currently ignored. The response status is `201` and its JSON fields are `id`, `viewer_url`, and `created_at`.

`GET /v1/sessions/{id}` returns the stored session with `200`. A missing ID returns `404`.

`DELETE /v1/sessions/{id}` removes the session and returns `204`. A missing ID returns `404`.

Known routes reject unsupported methods with `405` and an `Allow` header. Client errors use this shape:

```json
{"error":{"code":"session_not_found","message":"session not found"}}
```

Request bodies are limited to 1 MiB. The service accepts `application/json` with an optional media-type parameter, such as `charset=utf-8`.

## Storage

The service uses the Go standard library and stores sessions in a JSON object at `GHOSTLIGHT_STORE_PATH`. `FileStore` protects in-process reads and writes with `sync.RWMutex`. Each write encodes the complete map, syncs a temporary file in the target directory, and renames that file over the store path.

The file store supports one service process per path. It does not coordinate writes from multiple processes, so a multi-process deployment needs SQLite or another shared store.

## Container healthcheck

The final image includes `wget`. The supported in-container healthcheck command is:

```sh
wget -q -O /dev/null http://127.0.0.1:8080/healthz
```

Build and run the image with:

```sh
docker build -t ghostlight-control ./control
docker run --rm -p 8080:8080 \
  -e GHOSTLIGHT_VIEWER_URL=https://viewer.example.test \
  -v ghostlight-control-data:/data \
  ghostlight-control
```
