// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"os"
	"path/filepath"
	"slices"
	"testing"
)

// `cyfr update` notes each service of the bundled stack a project's compose
// file lacks, and the shipped compose file lacks none.
func TestMissingStackServices(t *testing.T) {
	if got := missingStackServices(filepath.Join("..", "..", "..", "docker-compose.yml")); got != nil {
		t.Errorf("the shipped docker-compose.yml lacks %v", got)
	}

	path := filepath.Join(t.TempDir(), "docker-compose.yml")
	old := `services:
  cyfr:
    image: ghcr.io/cyfrworks/cyfr:latest
  mcp-bridge:
    build:
      context: .
  caddy:
    image: caddy:2.11-alpine
    profiles: ["tls"]
`
	if err := os.WriteFile(path, []byte(old), 0644); err != nil {
		t.Fatal(err)
	}
	if got := missingStackServices(path); !slices.Equal(got, []string{"opus", "locus-builds"}) {
		t.Errorf("a compose file with cyfr, mcp-bridge and caddy lacks %v", got)
	}

	if got := missingStackServices(filepath.Join(t.TempDir(), "missing.yml")); got != nil {
		t.Errorf("a missing compose file lacks %v", got)
	}
}
