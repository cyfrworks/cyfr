// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package scaffold

import (
	"io/fs"
	"path/filepath"
	"strings"
	"testing"
)

// TestIsManaged pins down which scaffold entries `cyfr update` is allowed to
// overwrite. Managed = the guides, the WIT definitions, and the AQUA files
// the scaffold ships — the soul, the shipped roles and every file inside a
// shipped scroll. Everything a member owns — config, the compose/proxy
// files, their own roles and scrolls, .env — must NOT be managed, or
// `cyfr update` would clobber them.
func TestIsManaged(t *testing.T) {
	managed := []string{
		"component-guide.md",
		"tincture-guide.md",
		"integration-guide.md",
		"wit",
		"wit/cyfr/oauth/token.wit",
		"aqua/aqua.md",
		"aqua/roles/builder.md",
		"aqua/roles/web.md",
		"aqua/skills/capability-acquisition/SKILL.md",
		"aqua/skills/capability-acquisition/references/notes.md",
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
		"aqua",
		"aqua/README.md",                     // only the soul, roles and scrolls ship
		"aqua/roles/custom.md",               // a member's own role
		"aqua/roles/builder.txt",             // a role is a .md file
		"aqua/roles/nested/builder.md",       // roles are flat
		"aqua/skills/custom/SKILL.md",        // a member's own scroll
		"aqua/skills/capability-acquisition", // a scroll is the files inside its directory
	}
	for _, p := range notManaged {
		if isManaged(p) {
			t.Errorf("expected %q NOT to be managed (must be preserved on update)", p)
		}
	}
}

// TestBundledPromptsMatchSeed binds the shipped rosters to the seed tree the
// scaffold tarball is packed from (scripts/scaffold-tarball.sh packs
// `-C seed aqua`, so seed/aqua/<path> lands in the tarball as aqua/<path>).
// A role or scroll added to seed without a roster entry would never be
// refreshed by `cyfr update`; a roster entry the seed no longer ships would
// match nothing.
func TestBundledPromptsMatchSeed(t *testing.T) {
	seedAqua := filepath.Join("..", "..", "..", "..", "seed", "aqua")

	soulShipped := false
	seedRoles := map[string]bool{}
	seedScrolls := map[string]bool{}

	err := filepath.WalkDir(seedAqua, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			return nil
		}
		rel, err := filepath.Rel(seedAqua, path)
		if err != nil {
			return err
		}
		rel = filepath.ToSlash(rel)
		tarPath := "aqua/" + rel

		switch {
		case rel == "aqua.md":
			soulShipped = true
			if !isManaged(tarPath) {
				t.Errorf("the soul %q is not managed — `cyfr update` will never refresh it", tarPath)
			}
		case strings.HasPrefix(rel, "roles/"):
			name, isMarkdown := strings.CutSuffix(strings.TrimPrefix(rel, "roles/"), ".md")
			if !isMarkdown || strings.Contains(name, "/") {
				return nil
			}
			seedRoles[name] = true
			if !isManaged(tarPath) {
				t.Errorf("shipped role %q is not managed — `cyfr update` will never refresh it", tarPath)
			}
		case strings.HasPrefix(rel, "skills/"):
			name, file, _ := strings.Cut(strings.TrimPrefix(rel, "skills/"), "/")
			if file != "SKILL.md" {
				return nil
			}
			seedScrolls[name] = true
			if !isManaged(tarPath) {
				t.Errorf("shipped scroll %q is not managed — `cyfr update` will never refresh it", tarPath)
			}
		}
		return nil
	})
	if err != nil {
		t.Fatalf("cannot walk the shipped seed tree at %s: %v", seedAqua, err)
	}

	if !soulShipped {
		t.Fatalf("no soul found at %s", filepath.Join(seedAqua, "aqua.md"))
	}
	if len(seedRoles) == 0 {
		t.Fatalf("no shipped roles found under %s", filepath.Join(seedAqua, "roles"))
	}
	if len(seedScrolls) == 0 {
		t.Fatalf("no shipped scrolls found under %s", filepath.Join(seedAqua, "skills"))
	}

	for name := range shippedRoles {
		if !seedRoles[name] {
			t.Errorf("shippedRoles names %q which the seed tree does not ship — a stale entry that matches nothing", name)
		}
	}
	for name := range shippedScrolls {
		if !seedScrolls[name] {
			t.Errorf("shippedScrolls names %q which the seed tree does not ship — a stale entry that matches nothing", name)
		}
	}

	// A member's own role or scroll must survive `cyfr update`. Guard the
	// made-up name so the assertion stays honest if seed ever ships it.
	const custom = "custom"
	if seedRoles[custom] || seedScrolls[custom] {
		t.Fatalf("the seed tree ships a role or scroll named %q; pick another name for the member-owned check", custom)
	}
	for _, p := range []string{"aqua/roles/custom.md", "aqua/skills/custom/SKILL.md"} {
		if isManaged(p) {
			t.Errorf("expected member-owned %q NOT to be managed (must be preserved on update)", p)
		}
	}
}
