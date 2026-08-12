FROM golang:1.24-alpine AS build

WORKDIR /src
COPY go.mod ./
COPY *.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/ghostlight-control .

FROM alpine:3.22

RUN apk add --no-cache wget \
    && addgroup -S ghostlight \
    && adduser -S -G ghostlight ghostlight \
    && mkdir -p /data \
    && chown ghostlight:ghostlight /data

COPY --from=build /out/ghostlight-control /usr/local/bin/ghostlight-control

ENV GHOSTLIGHT_LISTEN_ADDR=:8080
ENV GHOSTLIGHT_STORE_PATH=/data/sessions.json

EXPOSE 8080
VOLUME ["/data"]
USER ghostlight

HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
    CMD ["wget", "-q", "-O", "/dev/null", "http://127.0.0.1:8080/healthz"]

ENTRYPOINT ["/usr/local/bin/ghostlight-control"]
