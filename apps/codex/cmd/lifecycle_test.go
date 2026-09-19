// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"testing"
)

func TestRenderEnvFile(t *testing.T) {
	tmpl := "CYFR_SECRET_KEY_BASE=\nCYFR_MCP_BRIDGE_KEY=\nCYFR_HOST=localhost\nCYFR_BEHIND_PROXY=false\nCADDY_ACME_EMAIL=\n# CYFR_PLATFORM_ADMIN_EMAILS=alice@example.com\nCYFR_PORT=4000\n"

	// TLS mode: real hostname + allowed user + ACME email. tls=true flips
	// CYFR_BEHIND_PROXY.
	got := renderEnvFile(tmpl, "SEKRIT", "BRIDGEKEY", "example.com", "me@example.com", "ops@example.com", true)
	for _, want := range []string{
		"CYFR_SECRET_KEY_BASE=SEKRIT",
		"CYFR_MCP_BRIDGE_KEY=BRIDGEKEY",
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
	if strings.Contains(got, "# CYFR_MCP_BRIDGE_KEY=") {
		t.Errorf("CYFR_MCP_BRIDGE_KEY should be uncommented:\n%s", got)
	}

	// Direct mode: localhost, no allowed user, no ACME, tls=false. Comment
	// line untouched, ACME left blank, BEHIND_PROXY=false.
	got = renderEnvFile(tmpl, "SEKRIT", "BRIDGEKEY", "localhost", "", "", false)
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

	// A template that ships the bridge key commented out is filled in the
	// same way.
	got = renderEnvFile("# CYFR_MCP_BRIDGE_KEY=\n", "S", "BRIDGEKEY", "localhost", "", "", false)
	if !strings.Contains(got, "CYFR_MCP_BRIDGE_KEY=BRIDGEKEY") || strings.Contains(got, "# CYFR_MCP_BRIDGE_KEY=") {
		t.Errorf("commented CYFR_MCP_BRIDGE_KEY not filled in:\n%s", got)
	}
}

// The generated bridge key is 32 random bytes as 64 lowercase hexadecimal
// digits, the form cyfr and the bridge both accept, and never repeats.
func TestGenerateBridgeKey(t *testing.T) {
	first, err := generateBridgeKey()
	if err != nil {
		t.Fatal(err)
	}
	second, err := generateBridgeKey()
	if err != nil {
		t.Fatal(err)
	}
	if !regexp.MustCompile(`^[0-9a-f]{64}$`).MatchString(first) {
		t.Errorf("bridge key %q is not 64 hexadecimal digits", first)
	}
	if first == second {
		t.Error("two generated bridge keys are equal")
	}
}

// Verify substitution against the shipped .env.example, including
// every key the renderer must populate.
func TestRenderEnvFileShippedTemplate(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", ".env.example"))
	if err != nil {
		t.Fatalf("read shipped .env.example: %v", err)
	}

	got := renderEnvFile(string(raw), "SEKRIT", "BRIDGEKEY", "example.com", "me@example.com", "ops@example.com", true)
	for _, want := range []string{
		"\nCYFR_SECRET_KEY_BASE=SEKRIT\n",
		"\nCYFR_MCP_BRIDGE_KEY=BRIDGEKEY\n",
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
    profiles: ["tls"]
  locus-builds:
    image: ghcr.io/cyfrworks/cyfr-locus:latest
    profiles: ["locus-builds"]
  mcp-bridge:
    build:
      context: .
      dockerfile: Dockerfile.node
`
	if err := os.WriteFile(path, []byte(body), 0644); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		profiles []string
		want     []string
	}{
		{nil, []string{"ghcr.io/cyfrworks/cyfr:latest"}},
		{[]string{"locus-builds"}, []string{"ghcr.io/cyfrworks/cyfr:latest", "ghcr.io/cyfrworks/cyfr-locus:latest"}},
		{[]string{"tls", "locus-builds"}, []string{"ghcr.io/cyfrworks/cyfr:latest", "caddy:2-alpine", "ghcr.io/cyfrworks/cyfr-locus:latest"}},
		{[]string{"other"}, []string{"ghcr.io/cyfrworks/cyfr:latest"}},
	} {
		got := imagesFromCompose(path, tc.profiles)
		if strings.Join(got, ",") != strings.Join(tc.want, ",") {
			t.Errorf("profiles %v: images mismatch\n  got:  %v\n  want: %v", tc.profiles, got, tc.want)
		}
	}

	if imagesFromCompose(filepath.Join(dir, "missing.yml"), nil) != nil {
		t.Error("expected nil for a missing file")
	}
}

func TestComposeProfilesFollowTheProjectEnv(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, ".env")
	cases := []struct {
		body string
		want []string
	}{
		{"", nil},
		{"CYFR_BEHIND_PROXY=true\n", []string{"tls"}},
		{"CYFR_LOCUS_BUILDS_URL=http://locus-builds:4100\n", []string{"locus-builds"}},
		{"CYFR_BEHIND_PROXY=yes\nCYFR_LOCUS_BUILDS_URL=\"http://locus-builds:4100\"\n", []string{"tls", "locus-builds"}},
		{"# CYFR_LOCUS_BUILDS_URL=http://locus-builds:4100\n", nil},
		{"CYFR_LOCUS_BUILDS_URL=\n", nil},
		{"CYFR_LOCUS_BUILDS_URL=https://builds.example.com\n", nil},
		// The retired variable and host start nothing: a project still
		// carrying them builds nothing until it names the builds service.
		{"CYFR_" + "BUILDER_URL=http://builder:4100\n", nil},
		{"CYFR_LOCUS_BUILDS_URL=http://builder:4100\n", nil},
	}
	for _, tc := range cases {
		if err := os.WriteFile(path, []byte(tc.body), 0644); err != nil {
			t.Fatal(err)
		}
		if got := composeProfiles(path); strings.Join(got, ",") != strings.Join(tc.want, ",") {
			t.Errorf("composeProfiles(%q) = %v, want %v", tc.body, got, tc.want)
		}
	}
	if got := composeProfiles(filepath.Join(dir, "missing")); got != nil {
		t.Errorf("a missing .env selects %v", got)
	}

	if got := profileArgs([]string{"tls", "locus-builds"}); strings.Join(got, " ") != "--profile tls --profile locus-builds" {
		t.Errorf("profileArgs = %v", got)
	}
}

// The shipped compose file and .env.example: a project that points builds at
// the locus-builds service pulls and starts the cyfr-locus image, and the
// value .env.example offers is the one that does.
func TestShippedComposePullsTheBuilderWhenBuildsUseIt(t *testing.T) {
	const image = "ghcr.io/cyfrworks/cyfr-locus:latest"
	compose := filepath.Join("..", "..", "..", "docker-compose.yml")
	if got := imagesFromCompose(compose, nil); slices.Contains(got, image) {
		t.Errorf("the builds image is pulled without its profile: %v", got)
	}

	raw, err := os.ReadFile(filepath.Join("..", "..", "..", ".env.example"))
	if err != nil {
		t.Fatalf("read shipped .env.example: %v", err)
	}
	var offered string
	for _, line := range strings.Split(string(raw), "\n") {
		if strings.HasPrefix(line, "# CYFR_LOCUS_BUILDS_URL=") {
			offered = strings.TrimPrefix(line, "# ")
		}
	}
	if offered == "" {
		t.Fatal(".env.example offers no CYFR_LOCUS_BUILDS_URL")
	}

	env := filepath.Join(t.TempDir(), ".env")
	if err := os.WriteFile(env, []byte(offered+"\n"), 0644); err != nil {
		t.Fatal(err)
	}
	if got := imagesFromCompose(compose, composeProfiles(env)); !slices.Contains(got, image) {
		t.Errorf("a project using the builds service (%s) does not pull its image: %v", offered, got)
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
