# syntax=docker/dockerfile:1.18

FROM golang:1.26.6-trixie@sha256:ab563819a16cfe5faff0f96a8bb598fbb0e400ab2ac751996e60abcb23b106a3 AS neko-builder

ARG NEKO_REVISION=395ca1a6f62b7b0e270e654d366a2d57b8042efd
ARG NEKO_SOURCE_SHA256=148de6806aea9c523d635ca187ecd5d96442c694cf62043791e43328d3ad83dc
ARG SOURCE_DATE_EPOCH=1785940131
ARG DEBIAN_SNAPSHOT=20260813T161554Z

WORKDIR /build

RUN set -eux; \
    printf '%s\n' \
      "deb [check-valid-until=no] https://snapshot.debian.org/archive/debian/${DEBIAN_SNAPSHOT} trixie main" \
      "deb [check-valid-until=no] https://snapshot.debian.org/archive/debian/${DEBIAN_SNAPSHOT} trixie-updates main" \
      "deb [check-valid-until=no] https://snapshot.debian.org/archive/debian-security/${DEBIAN_SNAPSHOT} trixie-security main" \
      >/etc/apt/sources.list; \
    rm -f /etc/apt/sources.list.d/debian.sources; \
    apt-get -o Acquire::Check-Valid-Until=false update; \
    apt-get install --yes --no-install-recommends \
      ca-certificates curl patch libx11-dev libxrandr-dev libxtst-dev libgtk-3-dev libxcvt-dev \
      libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev; \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/*; \
    curl --fail --location --proto '=https' --tlsv1.2 \
      "https://codeload.github.com/m1k1o/neko/tar.gz/${NEKO_REVISION}" \
      --output neko.tar.gz; \
    echo "${NEKO_SOURCE_SHA256}  neko.tar.gz" | sha256sum --check --strict; \
    mkdir source; \
    tar --extract --gzip --file neko.tar.gz --directory source --strip-components=1; \
    printf '%s\n' 'Apache-2.0 Neko source' >SOURCE-PROVENANCE

COPY neko-go-modules.patch /build/neko-go-modules.patch

RUN set -eux; \
    cd /build/source/server; \
    test "$(sha256sum go.mod | cut -d' ' -f1)" = a9102a6a216e149cd2a02a2eba5c6416976bdb2db421c5055c7142c05b7c3dfb; \
    test "$(sha256sum go.sum | cut -d' ' -f1)" = 1b0b1eee88525b492fb4430a17d1eb632e2bcc2b2d60fbab1f00a0a3ef7b260c; \
    patch --fuzz=0 --no-backup-if-mismatch --strip=2 < /build/neko-go-modules.patch; \
    test "$(sha256sum go.mod | cut -d' ' -f1)" = 77d3961cb7d266b0e7136ea40bf76ca75c9d47c22532de989def59c83e817834; \
    test "$(sha256sum go.sum | cut -d' ' -f1)" = 5f5a503acc0e37497dad316600bdb3f981bdf272d66d9923ec87b0e1b944641f; \
    go mod download; \
    go mod verify; \
    go test -mod=readonly ./...; \
    CGO_ENABLED=1 go build -mod=readonly -buildvcs=false -trimpath \
      -ldflags "-buildid= -s -w -X 'github.com/m1k1o/neko/server.buildDate=2026-08-05T14:28:51Z' -X 'github.com/m1k1o/neko/server.gitCommit=${NEKO_REVISION}' -X 'github.com/m1k1o/neko/server.gitBranch=detached' -X 'github.com/m1k1o/neko/server.gitTag=v3.1.5'" \
      -o /build/neko ./cmd/neko/main.go; \
    touch --date="@${SOURCE_DATE_EPOCH}" /build/neko

COPY bridge /build/ghostlight-bridge

RUN set -eux; \
    cd /build/ghostlight-bridge; \
    go mod download; \
    go mod verify; \
    go test -mod=readonly ./...; \
    CGO_ENABLED=0 go build -mod=readonly -buildvcs=false -trimpath \
      -ldflags "-buildid= -s -w" \
      -o /build/ghostlight-native-host .; \
    touch --date="@${SOURCE_DATE_EPOCH}" /build/ghostlight-native-host

FROM ghcr.io/m1k1o/neko/chromium@sha256:a79093411aced75b3ed7110d50ec9082f9933afabd6592254f01c383678082e7

ARG GHOSTLIGHT_REVISION=unknown

USER root

# intel-media-va-driver-non-free ships only for amd64, so it installs behind an
# architecture gate. All three GPU packages are inert until
# runtime/docker-compose.gpu.yml passes /dev/dri and the GPU Chromium flags.
RUN set -eux; \
    printf '%s\n' \
      'Types: deb' \
      'URIs: https://snapshot.debian.org/archive/debian/20260813T161554Z' \
      'Suites: trixie trixie-updates' \
      'Components: main non-free' \
      'Signed-By: /usr/share/keyrings/debian-archive-keyring.pgp' \
      'Check-Valid-Until: no' \
      '' \
      'Types: deb' \
      'URIs: https://snapshot.debian.org/archive/debian-security/20260813T161554Z' \
      'Suites: trixie-security' \
      'Components: main' \
      'Signed-By: /usr/share/keyrings/debian-archive-keyring.pgp' \
      'Check-Valid-Until: no' \
      > /etc/apt/sources.list.d/debian.sources; \
    apt-get -o Acquire::Check-Valid-Until=false update; \
    apt-get install --yes --no-install-recommends --only-upgrade \
      chromium=151.0.7922.137-1~deb13u1 \
      chromium-common=151.0.7922.137-1~deb13u1 \
      chromium-sandbox=151.0.7922.137-1~deb13u1 \
      libheif1=1.19.8-1+deb13u1 \
      libheif-plugin-dav1d=1.19.8-1+deb13u1 \
      libheif-plugin-libde265=1.19.8-1+deb13u1; \
    apt-get install --yes --no-install-recommends \
      gstreamer1.0-vaapi=1.26.2-1 \
      vainfo=2.22.0+ds1-2; \
    if [ "$(dpkg --print-architecture)" = amd64 ]; then \
      apt-get install --yes --no-install-recommends \
        intel-media-va-driver-non-free=25.2.3+ds1-1; \
    fi; \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/*

COPY --from=neko-builder /build/neko /usr/bin/neko
COPY --from=neko-builder /build/ghostlight-native-host /usr/local/bin/ghostlight-native-host
COPY --from=neko-builder /build/source/LICENSE /usr/share/doc/neko/LICENSE
COPY --from=neko-builder /build/SOURCE-PROVENANCE /usr/share/doc/neko/SOURCE-PROVENANCE
COPY extension /opt/ghostlight/browser-agent
COPY native-messaging-host.json /etc/chromium/native-messaging-hosts/org.evalops.ghostlight.browser_agent.json
COPY chromium.conf /etc/neko/supervisord/chromium.conf

RUN set -eux; \
    chmod 0755 /usr/local/bin/ghostlight-native-host; \
    chmod -R a-w /opt/ghostlight/browser-agent; \
    chmod 0644 /etc/chromium/native-messaging-hosts/org.evalops.ghostlight.browser_agent.json \
      /etc/neko/supervisord/chromium.conf

LABEL org.opencontainers.image.source="https://github.com/evalops/ghostlight" \
      org.opencontainers.image.description="Ghostlight hardened Neko Chromium 3.1.5 viewer with a native browser-session agent" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.version="neko-v3.1.5-ghostlight.4" \
      org.opencontainers.image.revision="${GHOSTLIGHT_REVISION}"
