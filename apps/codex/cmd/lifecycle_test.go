package cmd

import (
	"strings"
	"testing"
)

func TestRenderEnvFile(t *testing.T) {
	tmpl := "CYFR_SECRET_KEY_BASE=\nCYFR_HOST=localhost\nCADDY_ACME_EMAIL=\n# CYFR_ALLOWED_USER=alice@example.com\nCYFR_PORT=4000\n"

	// Real hostname + allowed user + ACME email: all substituted, allowed-user uncommented.
	got := renderEnvFile(tmpl, "SEKRIT", "example.com", "me@example.com", "ops@example.com")
	for _, want := range []string{
		"CYFR_SECRET_KEY_BASE=SEKRIT",
		"CYFR_HOST=example.com",
		"CADDY_ACME_EMAIL=ops@example.com",
		"CYFR_ALLOWED_USER=me@example.com",
		"CYFR_PORT=4000",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("missing %q in:\n%s", want, got)
		}
	}
	if strings.Contains(got, "# CYFR_ALLOWED_USER=") {
		t.Errorf("CYFR_ALLOWED_USER should be uncommented:\n%s", got)
	}

	// localhost, no allowed user, no ACME email: comment line untouched, ACME left blank.
	got = renderEnvFile(tmpl, "SEKRIT", "localhost", "", "")
	if !strings.Contains(got, "# CYFR_ALLOWED_USER=alice@example.com") {
		t.Errorf("CYFR_ALLOWED_USER line should be untouched:\n%s", got)
	}
	if !strings.Contains(got, "CADDY_ACME_EMAIL=\n") {
		t.Errorf("CADDY_ACME_EMAIL should be left blank:\n%s", got)
	}
}

func TestFileExists(t *testing.T) {
	dir := t.TempDir()
	if fileExists(dir + "/nope") {
		t.Error("fileExists returned true for a missing path")
	}
	if !fileExists(dir) {
		t.Error("fileExists returned false for an existing directory")
	}
}
