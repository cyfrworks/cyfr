package cmd

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRenderEnvFile(t *testing.T) {
	tmpl := "CYFR_SECRET_KEY_BASE=\nCYFR_HOST=localhost\nCYFR_BEHIND_PROXY=false\nCYFR_PORTA_BIND=0.0.0.0:8080\nCADDY_ACME_EMAIL=\n# CYFR_PLATFORM_ADMIN_EMAILS=alice@example.com\nCYFR_PORT=4000\n"

	// TLS mode: real hostname + allowed user + ACME email. tls=true flips
	// CYFR_BEHIND_PROXY and CYFR_PORTA_BIND.
	got := renderEnvFile(tmpl, "SEKRIT", "example.com", "me@example.com", "ops@example.com", true)
	for _, want := range []string{
		"CYFR_SECRET_KEY_BASE=SEKRIT",
		"CYFR_HOST=example.com",
		"CYFR_BEHIND_PROXY=true",
		"CYFR_PORTA_BIND=127.0.0.1:8080",
		"CADDY_ACME_EMAIL=ops@example.com",
		"CYFR_PLATFORM_ADMIN_EMAILS=me@example.com",
		"CYFR_PORT=4000",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("missing %q in:\n%s", want, got)
		}
	}
	if strings.Contains(got, "# CYFR_PLATFORM_ADMIN_EMAILS=") {
		t.Errorf("CYFR_PLATFORM_ADMIN_EMAILS should be uncommented:\n%s", got)
	}

	// Direct mode: localhost, no allowed user, no ACME, tls=false. Comment
	// line untouched, ACME left blank, BEHIND_PROXY=false, PORTA_BIND public.
	got = renderEnvFile(tmpl, "SEKRIT", "localhost", "", "", false)
	if !strings.Contains(got, "# CYFR_PLATFORM_ADMIN_EMAILS=alice@example.com") {
		t.Errorf("CYFR_PLATFORM_ADMIN_EMAILS line should be untouched:\n%s", got)
	}
	if !strings.Contains(got, "CADDY_ACME_EMAIL=\n") {
		t.Errorf("CADDY_ACME_EMAIL should be left blank:\n%s", got)
	}
	if !strings.Contains(got, "CYFR_BEHIND_PROXY=false") {
		t.Errorf("CYFR_BEHIND_PROXY should be false in direct mode:\n%s", got)
	}
	if !strings.Contains(got, "CYFR_PORTA_BIND=0.0.0.0:8080") {
		t.Errorf("CYFR_PORTA_BIND should be 0.0.0.0:8080 in direct mode:\n%s", got)
	}
}

func TestImagesFromCompose(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "docker-compose.yml")
	body := `services:
  cyfr:
    image: ghcr.io/cyfrworks/cyfr:latest
  porta:
    image: ghcr.io/cyfrworks/cyfr-porta:latest
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
		"ghcr.io/cyfrworks/cyfr-porta:latest",
		"caddy:2-alpine",
	}
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Errorf("images mismatch\n  got:  %v\n  want: %v", got, want)
	}

	if imagesFromCompose(filepath.Join(dir, "missing.yml")) != nil {
		t.Error("expected nil for a missing file")
	}
}

func TestEnvFlagTrue(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, ".env")
	cases := []struct {
		body string
		key  string
		want bool
	}{
		{"CYFR_BEHIND_PROXY=true\n", "CYFR_BEHIND_PROXY", true},
		{"CYFR_BEHIND_PROXY=TRUE\n", "CYFR_BEHIND_PROXY", true},
		{"CYFR_BEHIND_PROXY=1\nCYFR_HOST=x\n", "CYFR_BEHIND_PROXY", true},
		{"CYFR_BEHIND_PROXY=false\n", "CYFR_BEHIND_PROXY", false},
		{"CYFR_BEHIND_PROXY=\n", "CYFR_BEHIND_PROXY", false},
		{"# CYFR_BEHIND_PROXY=true\n", "CYFR_BEHIND_PROXY", false},
		{"OTHER=true\n", "CYFR_BEHIND_PROXY", false},
		{`CYFR_BEHIND_PROXY="true"` + "\n", "CYFR_BEHIND_PROXY", true},
	}
	for _, tc := range cases {
		if err := os.WriteFile(path, []byte(tc.body), 0644); err != nil {
			t.Fatal(err)
		}
		if got := envFlagTrue(path, tc.key); got != tc.want {
			t.Errorf("envFlagTrue(%q)=%v, want %v\n  body: %q", tc.key, got, tc.want, tc.body)
		}
	}

	if envFlagTrue(filepath.Join(dir, "no-such-file"), "ANYTHING") {
		t.Error("envFlagTrue should be false for a missing file")
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
