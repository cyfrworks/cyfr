.PHONY: build clean test install fmt vet release snapshot

BINARY := cyfr
MODULE := github.com/cyfr/codex
VERSION ?= dev
COMMIT  ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo "none")
DATE    ?= $(shell date -u +%Y-%m-%dT%H:%M:%SZ)
LDFLAGS := -s -w -X github.com/cyfr/codex/internal/version.Version=$(VERSION) -X github.com/cyfr/codex/internal/version.Commit=$(COMMIT) -X github.com/cyfr/codex/internal/version.Date=$(DATE)

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
