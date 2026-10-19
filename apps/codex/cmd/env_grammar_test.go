// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// barredEnv is withBarrier's text for env, failing t when it refuses.
func barredEnv(t *testing.T, env []byte, snapshot string) []byte {
	t.Helper()
	out, err := withBarrier(env, snapshot)
	if err != nil {
		t.Fatalf("withBarrier refused %q: %v", env, err)
	}
	return out
}

// A single-quoted value holds a quote its backslash escapes and goes on
// across lines that look like assignments, the barrier's name among
// them; real compose reads them all as the one value. The barrier is
// appended after it, the value's bytes and compose's reading of it
// unchanged.
func TestRestoreBarKeepsAMultilineValueWithAnEscapedQuoteWhole(t *testing.T) {
	requireCompose(t)
	const original = "CUSTOM='first\\'quoted\nCYFR_RESTORE_INCOMPLETE: literal quoted data\nlast'\n"
	dir := t.TempDir()
	env := filepath.Join(dir, ".env")
	compose := filepath.Join(dir, "compose.yml")
	if err := os.WriteFile(compose, []byte("services:\n  cyfr:\n    image: scratch\n    env_file: .env\n"), 0600); err != nil {
		t.Fatal(err)
	}
	read := func(text string) map[string]string {
		t.Helper()
		if err := os.WriteFile(env, []byte(text), 0600); err != nil {
			t.Fatal(err)
		}
		c := exec.Command("docker", "compose", "-p", "sol-escaped-quote", "--project-directory", dir, "--env-file", env, "-f", compose, "config", "--format", "json")
		raw, err := c.Output()
		if err != nil {
			t.Fatalf("real Compose cannot read fixture: %v", err)
		}
		var cfg struct {
			Services map[string]struct {
				Environment map[string]string `json:"environment"`
			} `json:"services"`
		}
		if err := json.Unmarshal(raw, &cfg); err != nil {
			t.Fatal(err)
		}
		return cfg.Services["cyfr"].Environment
	}
	before := read(original)
	want := "first'quoted\nCYFR_RESTORE_INCOMPLETE: literal quoted data\nlast"
	if before["CUSTOM"] != want {
		t.Fatalf("Compose reads the valid multiline fixture as %q, want %q", before["CUSTOM"], want)
	}
	barred, err := withBarrier([]byte(original), "/tmp/snapshot")
	if err != nil {
		t.Fatalf("withBarrier refused a .env compose reads: %v", err)
	}
	got := string(barred)
	after := read(got)
	if after["CUSTOM"] != before["CUSTOM"] {
		t.Errorf("the barrier changed Compose's unrelated CUSTOM from %q to %q", before["CUSTOM"], after["CUSTOM"])
	}
	if after[restoreBarrier] != "/tmp/snapshot" {
		t.Errorf("the barrier is %q in Compose, want /tmp/snapshot", after[restoreBarrier])
	}
	if !strings.HasPrefix(got, original) {
		t.Fatalf("the editor changed the unrelated multiline value after an escaped apostrophe:\noriginal: %q\nedited: %q", original, got)
	}
}
