.PHONY: build run test clean install

VERSION ?= dev
LDFLAGS := -X main.version=$(VERSION)

build:
	go build -ldflags "$(LDFLAGS)" -o claude-docker-tui .

run: build
	./claude-docker-tui

test:
	go test ./...

clean:
	rm -f claude-docker-tui claude-docker-tui-*

install: build
	cp claude-docker-tui /usr/local/bin/

build-all:
	GOOS=darwin GOARCH=arm64 go build -ldflags "$(LDFLAGS)" -o claude-docker-tui-darwin-arm64 .
	GOOS=linux GOARCH=amd64 go build -ldflags "$(LDFLAGS)" -o claude-docker-tui-linux-amd64 .
	GOOS=windows GOARCH=amd64 go build -ldflags "$(LDFLAGS)" -o claude-docker-tui-windows-amd64.exe .
