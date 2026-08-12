# Linux runtime

The runtime contains one [Apache-2.0-licensed Neko](https://github.com/m1k1o/neko/blob/master/LICENSE) Chromium viewer and one stateless Ghostlight control service. Docker Compose starts, restarts, and stops both containers. Chromium writes one profile to `runtime/data/chromium` by default.

## Configure

```sh
cp runtime/.env.example runtime/.env
chmod 600 runtime/.env
```

Replace the three install markers in `runtime/.env`:

- Generate different values for `NEKO_USER_PASSWORD` and `NEKO_ADMIN_PASSWORD`.
- Set `NEKO_WEBRTC_NAT1TO1` to the Linux address reachable from the client.

Set `GHOSTLIGHT_BIND_ADDRESS` to the loopback or private Linux address that should receive published ports. Set the host in `GHOSTLIGHT_VIEWER_URL` to the same value as `NEKO_WEBRTC_NAT1TO1`.

Example for a Linux host address:

```dotenv
GHOSTLIGHT_BIND_ADDRESS=<linux-host>
GHOSTLIGHT_VIEWER_URL=http://<linux-host>:8081
GHOSTLIGHT_VIEWER_HEALTH_URL=http://viewer:8080
NEKO_WEBRTC_NAT1TO1=<linux-host>
```

The Compose model requires an explicit bind address. Preflight accepts literal IPv4 loopback, link-local, or RFC 1918 addresses and IPv6 loopback, link-local, or unique-local addresses. It rejects hostnames, public addresses, wildcard addresses, and malformed IP literals. The operator must still confirm that the accepted address belongs to the intended host interface and apply firewall rules.

## Start and inspect

Run from the repository root:

```sh
runtime/bin/preflight.sh
docker compose up -d
runtime/bin/smoke.sh
```

`compose.yaml` loads `runtime/docker-compose.yml` and `runtime/.env`, which permits flag-free root commands after configuration.

```sh
docker compose ps
docker compose logs --tail=100 viewer control
docker compose down
```

The viewer uses `restart: unless-stopped`, a 2 GiB shared-memory allocation, and the digest-pinned `NEKO_IMAGE`. The control container starts only after the viewer healthcheck receives a successful response from Neko `/health`. Inside Compose, `GHOSTLIGHT_VIEWER_HEALTH_URL=http://viewer:8080` gives control a reachable service-network health target while `GHOSTLIGHT_VIEWER_URL` remains the client-facing address returned by discovery.

## Preflight checks

`runtime/bin/preflight.sh` performs these checks without starting the Compose services:

1. Requires Docker, Compose, `curl`, and `awk`.
2. Requires a regular, non-symlink environment file with mode `600`.
3. Rejects unresolved install markers and bind addresses outside the accepted literal private, link-local, and loopback ranges.
4. Requires the host in `GHOSTLIGHT_VIEWER_URL` to match `NEKO_WEBRTC_NAT1TO1`.
5. Renders the Compose model and checks that `control/Dockerfile` exists.
6. Creates the default Chromium profile with mode `700` when absent, then rejects a non-directory, symlink, or profile path with another mode.
7. Runs the digest-pinned Neko image as uid `1000` to create and remove a marker in the profile.

The uid check confirms that Neko uid `1000` can create and remove a marker in the profile before the documented Compose startup. `GHOSTLIGHT_SKIP_PROFILE_RUNTIME_CHECK=1` exists for the shell-test fixture and skips the container-side write check.

## Published ports

| Service | Default port | Protocol | Use |
| --- | ---: | --- | --- |
| Control | `8080` | TCP | Liveness, readiness, and viewer discovery |
| Viewer | `8081` | TCP | Neko login, viewer page, and signaling |
| WebRTC mux | `52000` | UDP and TCP | Browser audio, video, and input |

Each port publication uses `GHOSTLIGHT_BIND_ADDRESS`. Keep the host and container WebRTC mux ports identical; Neko advertises that port during ICE negotiation.

## Health and smoke checks

The viewer healthcheck calls Neko `/health`. The control container healthcheck calls `GET /readyz`, which performs another viewer `/health` request through `GHOSTLIGHT_VIEWER_HEALTH_URL`. Compose defaults that value to the internal address `http://viewer:8080`; the client-facing `GHOSTLIGHT_VIEWER_URL` remains the value returned by discovery. `GET /healthz` checks only the Go process.

`runtime/bin/smoke.sh` retries control liveness, direct viewer health, and control readiness up to 30 times by default. It then requests `GET /v1/viewer` once and checks `/health` through the returned viewer URL. Set `SMOKE_ATTEMPTS` to change the retry count.

## Chromium profile

Compose bind-mounts `runtime/data/chromium` at `/home/neko/.config/chromium`. `runtime/chromium-policy.json` sets `DefaultCookiesSetting` to allow cookies and `RestoreOnStartup` to restore the previous session. The profile may contain cookies, local storage, browsing and download history, and website credentials. Downloaded files are outside this mount at `/home/neko/Downloads`.

`docker compose down` removes containers and networks while leaving the host profile. Removing or replacing `runtime/data/chromium` removes the persisted browser state from the next viewer start.

## Profile backup

Create a backup while the configured Compose stack is available:

```sh
runtime/bin/profile-backup.sh backup \
  runtime/data/chromium \
  /safe/backup/ghostlight-profile.tar.gz
docker compose start viewer
```

The backup command validates the source tree, stops the viewer, and leaves it stopped. Source validation allows directories and regular files, omits Chromium's top-level `SingletonCookie`, `SingletonLock`, and `SingletonSocket`, and rejects other links or special files. Path validation rejects operator-controlled symlink components; on macOS it permits a root-owned top-level platform alias such as `/var`. A per-target lock plus temporary files prevents concurrent or partial publication. A successful run atomically publishes a mode-`600` gzip-compressed tar archive with numeric-owner metadata and a mode-`600` `<archive>.sha256` sidecar.

Restore into a new absolute path:

```sh
runtime/bin/profile-backup.sh restore \
  /safe/backup/ghostlight-profile.tar.gz \
  /safe/restore/chromium
```

Restore requires the sidecar to contain exactly one SHA-256 digest and verifies it before extraction. Archive validation permits one root containing directories and regular files with unique relative paths. It rejects absolute paths, dot or parent components, duplicate entries, multiple roots, links, and special files. Restore rejects symlink path components and an existing destination, extracts into a temporary sibling, sets mode `700`, and renames the result into the requested absolute path. It does not replace the active profile, modify Compose, or start the viewer.

`PROFILE_BACKUP_SKIP_COMPOSE=1` skips the viewer stop for the isolated shell-test fixture. Do not use that setting against an active Chromium profile.

Store the archive and sidecar as credential-bearing material. Test a restore into an isolated path before depending on a backup.

## Tests

```sh
runtime/tests/test_runtime.sh
runtime/tests/test_profile_backup.sh
```

The runtime test checks configuration contracts, shell syntax, optional ShellCheck output, flag-free Compose rendering, bind-address propagation, and profile backup behavior. The backup test verifies synthetic cookie, tab, and local-storage recovery; file-mode preservation; exact archive mode; checksum and collision failures; source and path link rejection; archive traversal rejection; and embedded-link rejection.

## Image update lane

The Neko reference in `.env.example` is mirrored in `docker-compose.yml` and `tests/test_runtime.sh`. `scripts/update-neko-image.sh` accepts only a canonical `ghcr.io/m1k1o/neko/chromium@sha256:<digest>` reference and updates those three files together. `scripts/check-image-safety.sh` rejects mismatched Neko references, mutable Docker bases, and GitHub Actions that lack a full commit SHA.

The scheduled browser-update workflow resolves Neko plus both control base tags, builds the candidate, runs these runtime and backup checks, runs the live synthetic Linux persistence lane, and scans the candidate viewer and control images. The workflow opens a digest-update pull request only after those blocking jobs succeed. It does not merge the pull request or change a running Linux host.
