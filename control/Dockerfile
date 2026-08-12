FROM golang:1.26.5-alpine@sha256:0178a641fbb4858c5f1b48e34bdaabe0350a330a1b1149aabd498d0699ff5fb2 AS build

WORKDIR /src
COPY go.mod ./
COPY *.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/ghostlight-control .

FROM alpine:3.22@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce

RUN apk add --no-cache wget \
    && addgroup -S ghostlight \
    && adduser -S -G ghostlight ghostlight

COPY --from=build /out/ghostlight-control /usr/local/bin/ghostlight-control

ENV GHOSTLIGHT_LISTEN_ADDR=:8080

EXPOSE 8080
USER ghostlight

HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
    CMD ["wget", "-q", "-O", "/dev/null", "http://127.0.0.1:8080/readyz"]

ENTRYPOINT ["/usr/local/bin/ghostlight-control"]
