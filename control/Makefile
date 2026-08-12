.PHONY: test test-race build run

test:
	go test ./...

test-race:
	go test -race ./...

build:
	CGO_ENABLED=0 go build -trimpath -o ghostlight-control .

run:
	GHOSTLIGHT_VIEWER_URL=http://127.0.0.1:3000 go run .
