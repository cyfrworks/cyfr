// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package scaffold

import (
	"os"
	"path/filepath"
	"testing"
)

// TestIsManaged pins down which scaffold entries `cyfr update` is allowed to
// overwrite. Managed = the docs, the WIT definitions, and the bundled aqua
// prompts (under the v3 aqua/agents/ layout). Everything the user owns —
// config, the compose/proxy files, custom prompts, .env — must NOT be
// managed, or `cyfr update` would clobber them.
func TestIsManaged(t *testing.T) {
	managed := []string{
		"component-guide.md",
		"tincture-guide.md",
		"integration-guide.md",
		"wit",
		"wit/cyfr/oauth/token.wit",
		"aqua/agents/aqua.md",
		"aqua/agents/aqua_builder.md",
		"aqua/agents/aqua_web.md",
	}
	for _, p := range managed {
		if !isManaged(p) {
			t.Errorf("expected %q to be managed (overwritten on update)", p)
		}
	}

	notManaged := []string{
		"docker-compose.yml",
		"Caddyfile",
		".env",
		".env.example",
		"Dockerfile.node",
		"apps/mcp-bridge/server.mjs",
		"cyfr.yaml",
		"aqua/aqua.md",               // the retired v2 flat spelling ships in no tarball
		"aqua/agents/aqua_custom.md", // user-created prompt
	}
	for _, p := range notManaged {
		if isManaged(p) {
			t.Errorf("expected %q NOT to be managed (must be preserved on update)", p)
		}
	}
}

// TestBundledPromptsMatchSeed binds bundledAquaPrompts to the seed tree the
// scaffold tarball is built from (scripts/scaffold-tarball.sh packs
// `-C seed aqua`). The v2→v3 layout move was invisible to TestIsManaged —
// both the map and its test spelled the same stale flat paths, so `cyfr
// update` silently stopped refreshing every shipped prompt.
func TestBundledPromptsMatchSeed(t *testing.T) {
	seedAgents := filepath.Join("..", "..", "..", "..", "seed", "aqua", "agents")

	entries, err := os.ReadDir(seedAgents)
	if err != nil {
		t.Fatalf("cannot read the shipped seed tree at %s: %v", seedAgents, err)
	}

	shipped := map[string]bool{}
	for _, e := range entries {
		if e.IsDir() || filepath.Ext(e.Name()) != ".md" {
			continue
		}
		shipped["aqua/agents/"+e.Name()] = true
	}

	if len(shipped) == 0 {
		t.Fatalf("no shipped prompts found under %s", seedAgents)
	}

	for p := range shipped {
		if !bundledAquaPrompts[p] {
			t.Errorf("shipped prompt %q is not in bundledAquaPrompts — `cyfr update` will never refresh it", p)
		}
	}

	for p := range bundledAquaPrompts {
		if !shipped[p] {
			t.Errorf("bundledAquaPrompts names %q which the seed tree does not ship — a stale path that matches nothing", p)
		}
	}
}
