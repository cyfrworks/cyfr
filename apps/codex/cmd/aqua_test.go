// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"github.com/cyfr/codex/internal/output"
	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
)

// TestAquaCommandTree pins the surface: the parent reaches every server
// action a reader or a member needs, and the scrolls nest the way the
// CLI's other sub-resources do (`skills list` / `skills get`).
func TestAquaCommandTree(t *testing.T) {
	want := map[string][]string{
		"aqua":        {"list", "get", "status", "reset", "skills"},
		"aqua skills": {"list", "get"},
	}
	for path, names := range want {
		parent := findCommand(t, path)
		for _, name := range names {
			if sub, _, err := parent.Find([]string{name}); err != nil || sub == parent {
				t.Errorf("%q has no %q subcommand", path, name)
			}
		}
	}

	reset := findCommand(t, "aqua reset")
	if reset.Flags().Lookup("all") == nil {
		t.Errorf("aqua reset has no --all flag")
	}
	if !findCommand(t, "aqua skills").Runnable() {
		t.Errorf("a bare `cyfr aqua skills` should list the scrolls")
	}
}

// TestAquaHelpVocabulary keeps the help in the estate's words — the soul,
// its roles, the scrolls, the guides — across every string cobra prints.
func TestAquaHelpVocabulary(t *testing.T) {
	banned := []string{"agent", "orchestrator", "sub-agent"}
	var walk func(c *cobra.Command)
	walk = func(c *cobra.Command) {
		texts := []string{c.Use, c.Short, c.Long, c.Example}
		c.Flags().VisitAll(func(f *pflag.Flag) { texts = append(texts, f.Usage) })
		for _, text := range texts {
			lower := strings.ToLower(text)
			for _, word := range banned {
				if strings.Contains(lower, word) {
					t.Errorf("%q help says %q: %q", c.CommandPath(), word, text)
				}
			}
		}
		for _, sub := range c.Commands() {
			walk(sub)
		}
	}
	walk(findCommand(t, "aqua"))

	long := findCommand(t, "aqua").Long
	for _, word := range []string{"soul", "roles", "scrolls", "guides"} {
		if !strings.Contains(long, word) {
			t.Errorf("aqua's Long should name the %s it manages, got:\n%s", word, long)
		}
	}
}

func TestRenderAquaList(t *testing.T) {
	result := map[string]any{
		"guides": []any{
			map[string]any{"name": "aqua", "title": "AQUA", "type": "soul", "description": "The estate's assistant"},
			map[string]any{"name": "builder", "title": "Builder", "type": "role", "description": "Builds components"},
			map[string]any{"name": "component-guide", "title": "Component Guide", "type": "doc", "description": "Building WASM components"},
		},
		"skills": []any{
			map[string]any{"name": "release-notes", "title": "release-notes", "description": "How to write release notes"},
		},
	}

	out := captureStdout(t, func() { renderAquaList(result) })

	// Sections in the server's order, each entry under its own heading.
	ordered := []string{
		"Soul", "aqua ", "AQUA — The estate's assistant",
		"Roles", "builder", "Builder — Builds components",
		"Guides", "component-guide", "Component Guide — Building WASM components",
		"Scrolls", "release-notes", "How to write release notes",
	}
	last := -1
	for _, want := range ordered {
		idx := strings.Index(out, want)
		if idx < 0 {
			t.Fatalf("expected %q in output, got:\n%s", want, out)
		}
		if idx < last {
			t.Errorf("%q appears out of order in:\n%s", want, out)
		}
		last = idx
	}
	// A scroll's title only repeats its name — not worth a column.
	if strings.Contains(out, "release-notes — How") {
		t.Errorf("a title equal to the name should be left out, got:\n%s", out)
	}
}

func TestRenderAquaList_NoScrolls(t *testing.T) {
	result := map[string]any{
		"guides": []any{
			map[string]any{"name": "aqua", "title": "AQUA", "type": "soul", "description": "The estate's assistant"},
		},
		"skills": []any{},
	}

	out := captureStdout(t, func() { renderAquaList(result) })

	for _, want := range []string{"Scrolls\n  none yet", "Roles\n  none"} {
		if !strings.Contains(out, want) {
			t.Errorf("expected %q in output, got:\n%s", want, out)
		}
	}
}

// TestRenderAquaList_ScrollsUnavailable: when the scroll index could not
// be fetched the first three sections still print, and the scrolls say
// why they are missing instead of the whole listing failing.
func TestRenderAquaList_ScrollsUnavailable(t *testing.T) {
	result := map[string]any{
		"guides": []any{
			map[string]any{"name": "aqua", "title": "AQUA", "type": "soul", "description": "The estate's assistant"},
			map[string]any{"name": "builder", "title": "Builder", "type": "role", "description": "Builds components"},
		},
		"skills_error": "connection reset",
	}

	out := captureStdout(t, func() { renderAquaList(result) })

	for _, want := range []string{"Soul", "aqua ", "Roles", "builder", "Guides\n  none", "Scrolls: unavailable (connection reset)"} {
		if !strings.Contains(out, want) {
			t.Errorf("expected %q in output, got:\n%s", want, out)
		}
	}
	for _, stray := range []string{"Scrolls\n", "none yet"} {
		if strings.Contains(out, stray) {
			t.Errorf("an unavailable index should print no scroll section, got:\n%s", out)
		}
	}
}

// TestWithScrolls pins the fold: the scrolls ride the listing under their
// wire key, and a failed second call leaves the listing intact with the
// error in the scrolls' place.
func TestWithScrolls(t *testing.T) {
	listing := func() map[string]any {
		return map[string]any{"guides": []any{map[string]any{"name": "aqua", "type": "soul"}}}
	}

	merged := withScrolls(listing(), map[string]any{"skills": []any{map[string]any{"name": "triage"}}, "count": float64(1)}, nil)
	if _, ok := merged["skills_error"]; ok {
		t.Errorf("a successful fetch should carry no skills_error, got %v", merged)
	}
	if got := mapsOf(merged["skills"]); len(got) != 1 || str(got[0]["name"]) != "triage" {
		t.Errorf("expected the scrolls under skills, got %v", merged["skills"])
	}

	failed := withScrolls(listing(), nil, errors.New("boom"))
	if _, ok := failed["skills"]; ok {
		t.Errorf("a failed fetch should carry no skills key, got %v", failed)
	}
	if str(failed["skills_error"]) != "boom" || len(mapsOf(failed["guides"])) != 1 {
		t.Errorf("expected the listing kept with skills_error, got %v", failed)
	}
}

// TestAquaList_JSONCarriesSkillsError: under --json a failed scroll fetch
// short-circuits to the merged result as JSON — the listing with a
// skills_error field and no skills — rather than an error exit.
func TestAquaList_JSONCarriesSkillsError(t *testing.T) {
	result := withScrolls(
		map[string]any{"guides": []any{map[string]any{"name": "aqua", "type": "soul"}}},
		nil, errors.New("boom"))

	out := captureStdout(t, func() { output.JSON(result) })

	var decoded map[string]any
	if err := json.Unmarshal([]byte(out), &decoded); err != nil {
		t.Fatalf("expected JSON, got %v:\n%s", err, out)
	}
	if decoded["skills_error"] != "boom" {
		t.Errorf("expected skills_error %q, got %v", "boom", decoded["skills_error"])
	}
	if _, ok := decoded["skills"]; ok {
		t.Errorf("expected no skills key, got %v", decoded["skills"])
	}
	if len(mapsOf(decoded["guides"])) != 1 {
		t.Errorf("expected the guides kept, got %v", decoded["guides"])
	}
	if strings.Contains(out, "Soul") {
		t.Errorf("--json should print no rendered sections, got:\n%s", out)
	}
}

func TestRenderAquaStatus(t *testing.T) {
	result := map[string]any{
		"files": []any{
			map[string]any{"path": "aqua/aqua.md", "state": "bundled_modified"},
			map[string]any{"path": "aqua/roles/builder.md", "state": "bundled"},
			map[string]any{"path": "aqua/skills/release-notes", "state": "user"},
		},
		"count": float64(3),
	}

	out := captureStdout(t, func() { renderAquaStatus(result) })

	for _, want := range []string{"PATH", "STATE", "aqua/aqua.md", "edited", "aqua/roles/builder.md", "bundled", "aqua/skills/release-notes", "yours"} {
		if !strings.Contains(out, want) {
			t.Errorf("expected %q in output, got:\n%s", want, out)
		}
	}
	for _, wire := range []string{"bundled_modified", "user"} {
		if strings.Contains(out, wire) {
			t.Errorf("wire state %q should be rendered in the CLI's words, got:\n%s", wire, out)
		}
	}
}

func TestRenderAquaStatus_Empty(t *testing.T) {
	out := captureStdout(t, func() { renderAquaStatus(map[string]any{"files": []any{}}) })
	if !strings.Contains(out, "No files.") {
		t.Errorf("expected empty-state message, got:\n%s", out)
	}
}

func TestRenderAquaReset(t *testing.T) {
	result := map[string]any{
		"reset":    true,
		"reverted": []any{"aqua/aqua.md"},
		"kept":     []any{"aqua/roles/mine.md", "aqua/skills/release-notes"},
	}

	out := captureStdout(t, func() { renderAquaReset(result, false) })

	for _, want := range []string{
		"Reverted to shipped:\n  aqua/aqua.md",
		"Kept (yours",
		"  aqua/roles/mine.md\n  aqua/skills/release-notes",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("expected %q in output, got:\n%s", want, out)
		}
	}
}

// TestRenderAquaReset_All: with --all the server's "reverted" list also
// holds what it deleted, so the heading must not call it all reverted.
func TestRenderAquaReset_All(t *testing.T) {
	result := map[string]any{
		"reset":    true,
		"reverted": []any{"aqua/aqua.md", "aqua/roles/mine.md", "aqua/skills/release-notes"},
		"kept":     []any{},
	}

	out := captureStdout(t, func() { renderAquaReset(result, true) })

	want := "Reverted or deleted:\n  aqua/aqua.md\n  aqua/roles/mine.md\n  aqua/skills/release-notes\n"
	if !strings.Contains(out, want) {
		t.Errorf("expected %q in output, got:\n%s", want, out)
	}
	for _, stray := range []string{"Reverted to shipped", "Kept"} {
		if strings.Contains(out, stray) {
			t.Errorf("--all should print neither %q nor a kept section, got:\n%s", stray, out)
		}
	}
}

func TestRenderAquaReset_NothingToRevert(t *testing.T) {
	result := map[string]any{"reset": true, "reverted": []any{}, "kept": []any{}}

	out := captureStdout(t, func() { renderAquaReset(result, false) })

	if !strings.Contains(out, "Nothing to revert") {
		t.Errorf("expected nothing-to-revert message, got:\n%s", out)
	}
	if strings.Contains(out, "Kept") {
		t.Errorf("an empty kept list should print no section, got:\n%s", out)
	}

	all := captureStdout(t, func() { renderAquaReset(result, true) })
	if !strings.Contains(all, "Nothing to revert or delete") {
		t.Errorf("expected the --all nothing-to-do message, got:\n%s", all)
	}
}

func TestRenderScrollList(t *testing.T) {
	result := map[string]any{
		"skills": []any{
			map[string]any{"name": "release-notes", "description": "How to write release notes"},
			map[string]any{"name": "triage", "description": "How to triage a report"},
		},
		"count": float64(2),
	}

	out := captureStdout(t, func() { renderScrollList(result) })

	for _, want := range []string{"NAME", "DESCRIPTION", "release-notes", "How to write release notes", "triage"} {
		if !strings.Contains(out, want) {
			t.Errorf("expected %q in output, got:\n%s", want, out)
		}
	}
}

func TestRenderScrollList_Empty(t *testing.T) {
	out := captureStdout(t, func() { renderScrollList(map[string]any{"skills": []any{}, "count": float64(0)}) })
	if !strings.Contains(out, "No scrolls yet") {
		t.Errorf("expected empty-state message, got:\n%s", out)
	}
}

func TestRenderScroll(t *testing.T) {
	result := map[string]any{
		"name":        "release-notes",
		"description": "How to write release notes",
		"format":      "markdown",
		"content":     "# Release notes\n\nLead with what changed for the reader.",
		"resources":   []any{"template.md", "examples/good.md"},
	}

	out := captureStdout(t, func() { renderScroll(result) })

	for _, want := range []string{
		"release-notes — How to write release notes",
		"Resources: template.md, examples/good.md",
		"\n\n# Release notes\n\nLead with what changed for the reader.",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("expected %q in output, got:\n%s", want, out)
		}
	}
}

func TestRenderScroll_NoDescriptionNoResources(t *testing.T) {
	result := map[string]any{"name": "bare", "content": "body", "resources": []any{}}

	out := captureStdout(t, func() { renderScroll(result) })

	if !strings.HasPrefix(out, "bare\n\nbody\n") {
		t.Errorf("expected the bare name, a blank line and the body, got:\n%q", out)
	}
	if strings.Contains(out, "Resources") {
		t.Errorf("no resources should print no line, got:\n%s", out)
	}
}

// findCommand resolves a space-separated path under the root, failing the
// test when cobra lands anywhere else.
func findCommand(t *testing.T, path string) *cobra.Command {
	t.Helper()
	c, _, err := rootCmd.Find(strings.Fields(path))
	if err != nil || c.CommandPath() != "cyfr "+path {
		t.Fatalf("no command at %q (got %v, %v)", path, c, err)
	}
	return c
}
