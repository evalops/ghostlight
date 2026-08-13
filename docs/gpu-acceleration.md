# GPU acceleration (experimental)

Status: **experimental and unverified**. No Ghostlight run on GPU hardware exists. The pinned published viewer image predates the packages below, so enabling this path requires a local image build that loses the published SBOM, provenance attestation, and vulnerability-scan receipt.

## What it changes

The shipped viewer runs Chromium with `--disable-gpu --disable-software-rasterizer` on `xserver-xorg-video-dummy`; every frame is rasterized in software and captured from the X screen. The opt-in override changes two things:

- `runtime/config/chromium-gpu.conf` replaces the baked-in `/etc/neko/supervisord/chromium.conf` and swaps `--disable-gpu` for the upstream Neko GPU flag set (`--ignore-gpu-blocklist`, `--enable-features=Vulkan,UseSkiaRenderer,VaapiVideoEncoder,VaapiVideoDecoder,CanvasOopRasterization`, `--use-angle=vulkan`, `--disable-vulkan-surface`, `--enable-unsafe-webgpu`). Page rasterization and in-browser video decode move to the Intel GPU.
- `runtime/docker-compose.gpu.yml` passes the host's `/dev/dri` into the viewer container and adds the host render-group GID to the container process.

It does not change the WebRTC capture pipeline: Neko still reads the X screen with `ximagesrc` and encodes in software. Routing capture through `vah264enc` hardware encode is a further step that requires a custom `NEKO_CAPTURE_VIDEO_PIPELINE` value; the default Compose file exposes `NEKO_CAPTURE_VIDEO_CODEC` and `NEKO_CAPTURE_VIDEO_PIPELINE` environment overrides for that experiment.

## Prerequisites

- Linux host with an Intel iGPU supported by the iHD driver (`intel-media-va-driver-non-free`), visible as `/dev/dri/renderD*`. The driver package is amd64-only, so this path does not apply to arm64 hosts.
- Docker Engine permitted to pass `/dev/dri` to containers.
- A locally rebuilt viewer image. The digest pinned in `runtime/.env.example` does not contain the VA-API packages.

## Enabling

```sh
# From the repository root.
docker build --tag ghostlight-viewer:gpu ./viewer

# Resolve the host group that owns the render node.
stat -c '%g' /dev/dri/renderD*
```

Set `NEKO_IMAGE=ghostlight-viewer:gpu` in `runtime/.env`. Set `RENDER_GID` there too if the `stat` output differs from the override's default of `109`. Then:

```sh
docker compose --env-file runtime/.env \
  -f runtime/docker-compose.yml -f runtime/docker-compose.gpu.yml up -d
```

Omitting `-f runtime/docker-compose.gpu.yml` restores the default software path.

## Verifying

- `docker exec <viewer-container> vainfo` lists the iHD driver and its H.264 decode/encode profiles. A failure to open `/dev/dri/renderD128` means the device or `RENDER_GID` mapping is wrong.
- `/var/log/neko/chromium.log` inside the container reports the GPU process outcome; Chromium falls back to software rasterization when GPU initialization fails, so a running browser alone is not evidence of acceleration.
- `docker stats` before and after, under the same `tests/acceptance/performance.mjs` workload, shows whether raster CPU moved off the Neko process. No paired receipt exists yet; record one in `docs/performance/` before treating the gain as real.

## Risks

- `--ignore-gpu-blocklist` and `--enable-unsafe-webgpu` widen the browser attack surface beyond the shipped configuration.
- The upstream GPU flag set comes from Neko's `supervisord.nvidia.conf` and is untested against the hardened image's Chromium build.
- A locally built image is not covered by the release-candidate vulnerability scan or the signed provenance of the published digest.
