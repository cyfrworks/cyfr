package cmd

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRenderEnvFile(t *testing.T) {
	tmpl := "CYFR_SECRET_KEY_BASE=\nCYFR_HOST=localhost\nCADDY_ACME_EMAIL=\nNEKO_PASSWORD=changeme\n# CYFR_ALLOWED_USER=alice@example.com\nCYFR_PORT=4000\n"

	// Real hostname + allowed user + ACME email + neko password: all substituted, allowed-user uncommented.
	got := renderEnvFile(tmpl, "SEKRIT", "example.com", "me@example.com", "ops@example.com", "n3k0pw")
	for _, want := range []string{
		"CYFR_SECRET_KEY_BASE=SEKRIT",
		"CYFR_HOST=example.com",
		"CADDY_ACME_EMAIL=ops@example.com",
		"NEKO_PASSWORD=n3k0pw",
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
	if strings.Contains(got, "NEKO_PASSWORD=changeme") {
		t.Errorf("NEKO_PASSWORD=changeme should have been replaced:\n%s", got)
	}

	// localhost, no allowed user, no ACME email, no neko password: comment line untouched,
	// ACME left blank, NEKO_PASSWORD untouched (so the .env.example placeholder stays).
	got = renderEnvFile(tmpl, "SEKRIT", "localhost", "", "", "")
	if !strings.Contains(got, "# CYFR_ALLOWED_USER=alice@example.com") {
		t.Errorf("CYFR_ALLOWED_USER line should be untouched:\n%s", got)
	}
	if !strings.Contains(got, "CADDY_ACME_EMAIL=\n") {
		t.Errorf("CADDY_ACME_EMAIL should be left blank:\n%s", got)
	}
	if !strings.Contains(got, "NEKO_PASSWORD=changeme") {
		t.Errorf("NEKO_PASSWORD should be untouched when no value supplied:\n%s", got)
	}
}

func TestImagesFromCompose(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "docker-compose.yml")
	body := `services:
  cyfr:
    image: ghcr.io/cyfrworks/cyfr:latest
  web:
    image: ghcr.io/cyfrworks/cyfr-web:latest
  caddy:
    image: caddy:2-alpine
  mcp-bridge:
    build:
      context: .
      dockerfile: Dockerfile.node
`
	if err := os.WriteFile(path, []byte(body), 0644); err != nil {
		t.Fatal(err)
	}
	got := imagesFromCompose(path)
	want := []string{
		"ghcr.io/cyfrworks/cyfr:latest",
		"ghcr.io/cyfrworks/cyfr-web:latest",
		"caddy:2-alpine",
	}
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Errorf("images mismatch\n  got:  %v\n  want: %v", got, want)
	}

	if imagesFromCompose(filepath.Join(dir, "missing.yml")) != nil {
		t.Error("expected nil for a missing file")
	}
}

func TestRandomToken(t *testing.T) {
	a, err := randomToken(24)
	if err != nil {
		t.Fatalf("randomToken err: %v", err)
	}
	if len(a) < 24 {
		t.Errorf("token too short: %q", a)
	}
	b, _ := randomToken(24)
	if a == b {
		t.Errorf("expected two random tokens to differ; got %q twice", a)
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
