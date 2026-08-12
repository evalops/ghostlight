FROM golang:1.25.12-trixie@sha256:c083e42786e39fb1a7dd4ae5ab02f5d80c3beb3224848ca0fa89f4a063a4ba29 AS build

ARG DEBIAN_SNAPSHOT=20260812T000000Z
ARG NEKO_REVISION=395ca1a6f62b7b0e270e654d366a2d57b8042efd
ENV DEBIAN_FRONTEND=noninteractive

RUN set -eux; \
    printf '%s\n' \
      "deb [check-valid-until=no] https://snapshot.debian.org/archive/debian/${DEBIAN_SNAPSHOT} trixie main" \
      "deb [check-valid-until=no] https://snapshot.debian.org/archive/debian/${DEBIAN_SNAPSHOT} trixie-updates main" \
      "deb [check-valid-until=no] https://snapshot.debian.org/archive/debian-security/${DEBIAN_SNAPSHOT} trixie-security main" \
      >/etc/apt/sources.list; \
    rm -f /etc/apt/sources.list.d/debian.sources; \
    apt-get -o Acquire::Check-Valid-Until=false update; \
    apt-get install -y --no-install-recommends \
      ca-certificates patch \
      libx11-dev libxrandr-dev libxtst-dev libgtk-3-dev libxcvt-dev \
      libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev; \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/*

ADD --checksum=sha256:148de6806aea9c523d635ca187ecd5d96442c694cf62043791e43328d3ad83dc \
  https://codeload.github.com/m1k1o/neko/tar.gz/395ca1a6f62b7b0e270e654d366a2d57b8042efd /tmp/neko.tar.gz
COPY neko-go-modules.patch /tmp/neko-go-modules.patch

RUN set -eux; \
    mkdir /src; \
    tar -xzf /tmp/neko.tar.gz --strip-components=1 -C /src; \
    cd /src; \
    patch -p1 </tmp/neko-go-modules.patch; \
    cd server; \
    go mod verify; \
    CGO_ENABLED=1 go build -trimpath -buildvcs=false \
      -ldflags="-s -w -X 'm1k1o/neko.buildDate=2026-08-12T00:00:00Z' -X 'm1k1o/neko.gitCommit=${NEKO_REVISION}' -X 'm1k1o/neko.gitBranch=v3' -X 'm1k1o/neko.gitTag=v3.1.5'" \
      -o /out/neko ./cmd/neko/main.go

FROM ghcr.io/m1k1o/neko/chromium@sha256:a79093411aced75b3ed7110d50ec9082f9933afabd6592254f01c383678082e7

ARG DEBIAN_SNAPSHOT=20260812T000000Z
USER root
RUN set -eux; \
    printf '%s\n' \
      "deb [check-valid-until=no] https://snapshot.debian.org/archive/debian/${DEBIAN_SNAPSHOT} trixie main" \
      "deb [check-valid-until=no] https://snapshot.debian.org/archive/debian/${DEBIAN_SNAPSHOT} trixie-updates main" \
      "deb [check-valid-until=no] https://snapshot.debian.org/archive/debian-security/${DEBIAN_SNAPSHOT} trixie-security main" \
      >/etc/apt/sources.list; \
    rm -f /etc/apt/sources.list.d/debian.sources; \
    apt-get -o Acquire::Check-Valid-Until=false update; \
    apt-get upgrade -y --no-install-recommends; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/*

COPY --from=build /out/neko /usr/bin/neko

LABEL org.opencontainers.image.source="https://github.com/evalops/ghostlight" \
      org.opencontainers.image.description="Ghostlight hardened Neko Chromium 3.1.5 viewer" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.version="3.1.5-ghostlight.1" \
      org.opencontainers.image.revision="395ca1a6f62b7b0e270e654d366a2d57b8042efd"
