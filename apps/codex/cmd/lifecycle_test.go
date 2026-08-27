package cmd

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRenderEnvFile(t *testing.T) {
	tmpl := "CYFR_SECRET_KEY_BASE=\nMCP_BRIDGE_TOKEN=\nCYFR_HOST=localhost\nCYFR_BEHIND_PROXY=false\nCADDY_ACME_EMAIL=\n# CYFR_PLATFORM_ADMIN_EMAILS=alice@example.com\nCYFR_PORT=4000\n"

	// TLS mode: real hostname + allowed user + ACME email. tls=true flips
	// CYFR_BEHIND_PROXY.
	got := renderEnvFile(tmpl, "SEKRIT", "BRIDGETOK", "example.com", "me@example.com", "ops@example.com", true)
	for _, want := range []string{
		"CYFR_SECRET_KEY_BASE=SEKRIT",
		"MCP_BRIDGE_TOKEN=BRIDGETOK",
		"CYFR_HOST=example.com",
		"CYFR_BEHIND_PROXY=true",
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
	if strings.Contains(got, "# MCP_BRIDGE_TOKEN=") {
		t.Errorf("MCP_BRIDGE_TOKEN should be uncommented:\n%s", got)
	}

	// Direct mode: localhost, no allowed user, no ACME, tls=false. Comment
	// line untouched, ACME left blank, BEHIND_PROXY=false.
	got = renderEnvFile(tmpl, "SEKRIT", "BRIDGETOK", "localhost", "", "", false)
	if !strings.Contains(got, "# CYFR_PLATFORM_ADMIN_EMAILS=alice@example.com") {
		t.Errorf("CYFR_PLATFORM_ADMIN_EMAILS line should be untouched:\n%s", got)
	}
	if !strings.Contains(got, "CADDY_ACME_EMAIL=\n") {
		t.Errorf("CADDY_ACME_EMAIL should be left blank:\n%s", got)
	}
	if !strings.Contains(got, "CYFR_BEHIND_PROXY=false") {
		t.Errorf("CYFR_BEHIND_PROXY should be false in direct mode:\n%s", got)
	}
	if strings.Contains(got, "PORTA") {
		t.Errorf("no porta variable belongs in .env:\n%s", got)
	}

	// A template that ships the bridge token commented out is filled in the
	// same way.
	got = renderEnvFile("# MCP_BRIDGE_TOKEN=\n", "S", "BRIDGETOK", "localhost", "", "", false)
	if !strings.Contains(got, "MCP_BRIDGE_TOKEN=BRIDGETOK") || strings.Contains(got, "# MCP_BRIDGE_TOKEN=") {
		t.Errorf("commented MCP_BRIDGE_TOKEN not filled in:\n%s", got)
	}
}

// The fixture-based test above proves the substitution rules; this one proves
// them against the .env.example that actually ships. A key the renderer is
// supposed to set but the template spells differently is exactly the bug that
// once left MCP_BRIDGE_TOKEN empty on every fresh install.
func TestRenderEnvFileShippedTemplate(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", ".env.example"))
	if err != nil {
		t.Fatalf("read shipped .env.example: %v", err)
	}

	got := renderEnvFile(string(raw), "SEKRIT", "BRIDGETOK", "example.com", "me@example.com", "ops@example.com", true)
	for _, want := range []string{
		"\nCYFR_SECRET_KEY_BASE=SEKRIT\n",
		"\nMCP_BRIDGE_TOKEN=BRIDGETOK\n",
		"\nCYFR_HOST=example.com\n",
		"\nCYFR_BEHIND_PROXY=true\n",
		"\nCADDY_ACME_EMAIL=ops@example.com\n",
		"\nCYFR_PLATFORM_ADMIN_EMAILS=me@example.com\n",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("shipped template: renderEnvFile did not produce %q", strings.TrimSpace(want))
		}
	}
}

func TestImagesFromCompose(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "docker-compose.yml")
	body := `services:
  cyfr:
    image: ghcr.io/cyfrworks/cyfr:latest
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
