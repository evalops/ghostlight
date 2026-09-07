FROM golang:1.27.1-alpine@sha256:cf6fca6641884b8433441b2b0652976f975e1d0fdd26d177eaaf8596087f3125 AS build

WORKDIR /src
COPY go.mod go.sum ./
COPY *.go ./
RUN go mod download \
    && go mod verify \
    && CGO_ENABLED=0 go build -mod=readonly -trimpath -ldflags="-s -w" -o /out/ghostlight-control .

FROM alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b

RUN apk add --no-cache wget \
    && addgroup -S ghostlight \
    && adduser -S -G ghostlight ghostlight \
    && install -d -m 0700 -o ghostlight -g ghostlight \
      /var/lib/ghostlight/state /var/lib/ghostlight/attachments

COPY --from=build /out/ghostlight-control /usr/local/bin/ghostlight-control

ENV GHOSTLIGHT_LISTEN_ADDR=:8080

EXPOSE 8080
USER ghostlight

HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
    CMD ["wget", "-q", "-O", "/dev/null", "http://127.0.0.1:8080/readyz"]

ENTRYPOINT ["/usr/local/bin/ghostlight-control"]
