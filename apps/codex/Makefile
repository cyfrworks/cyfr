.PHONY: build clean test install fmt vet release snapshot

BINARY := cyfr
MODULE := github.com/cyfr/codex
VERSION ?= dev
COMMIT  ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo "none")
DATE    ?= $(shell date -u +%Y-%m-%dT%H:%M:%SZ)
LDFLAGS := -s -w -X main.version=$(VERSION) -X main.commit=$(COMMIT) -X main.date=$(DATE)

build:
	go build -ldflags "$(LDFLAGS)" -o $(BINARY) .

clean:
	rm -f $(BINARY)

test:
	go test ./... -race

install:
	go install -ldflags "$(LDFLAGS)" .

fmt:
	gofmt -w .

vet:
	go vet ./...

release:
	goreleaser release --clean

snapshot:
	goreleaser release --snapshot --clean
