FROM golang:1.26.6-alpine@sha256:3889b425f035be855a72fb4755265311293b6d414521f0a519d819df32222d83 AS build

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
