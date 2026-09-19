// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"encoding/hex"
	"encoding/json"
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
	got := renderEnvFile(tmpl, "example.com", "me@example.com", "ops@example.com", true)
	for _, want := range []string{
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
	// The keys are ensureStackKeys', not the prompts'.
	if !strings.Contains(got, "CYFR_SECRET_KEY_BASE=\nCYFR_MCP_BRIDGE_KEY=\n") {
		t.Errorf("renderEnvFile touched a key:\n%s", got)
	}

	// Direct mode: localhost, no allowed user, no ACME, tls=false. Comment
	// line untouched, ACME left blank, BEHIND_PROXY=false.
	got = renderEnvFile(tmpl, "localhost", "", "", false)
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
}

// A generated key is 32 random bytes as 64 lowercase hexadecimal digits,
// the form cyfr, the bridge, the worker and the builder all accept, and
// never repeats.
func TestGenerateHexKey(t *testing.T) {
	first, err := generateHexKey()
	if err != nil {
		t.Fatal(err)
	}
	second, err := generateHexKey()
	if err != nil {
		t.Fatal(err)
	}
	if !regexp.MustCompile(`^[0-9a-f]{64}$`).MatchString(first) {
		t.Errorf("key %q is not 64 hexadecimal digits", first)
	}
	if first == second {
		t.Error("two generated keys are equal")
	}
}

// workerAuthVectors is the part of tests/fixtures/worker_auth.json, the
// vector file of Cyfr.WorkerAuth, that the CLI's derivation consumes.
type workerAuthVectors struct {
	RootHex  string `json:"root_hex"`
	Service  string `json:"service"`
	RootText struct {
		Valid   []string `json:"valid"`
		Invalid []string `json:"invalid"`
	} `json:"root_text"`
	Keys struct {
		WorkerHex string `json:"worker_hex"`
	} `json:"keys"`
}

// The service key init writes is Cyfr.WorkerAuth.worker_key/2's: the value
// the vector file records for its root and service, and the root is read
// as the platform reads CYFR_WORKER_KEY.
func TestWorkerKeyReproducesTheVectorFile(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "tests", "fixtures", "worker_auth.json"))
	if err != nil {
		t.Fatalf("read the vector file: %v", err)
	}
	var v workerAuthVectors
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatal(err)
	}
	if v.RootHex == "" || v.Service == "" || v.Keys.WorkerHex == "" || len(v.RootText.Valid) == 0 || len(v.RootText.Invalid) == 0 {
		t.Fatalf("the vector file lacks what this test reads: %+v", v)
	}

	root, ok := decodeHexKey(v.RootHex)
	if !ok {
		t.Fatalf("root_hex %q does not decode", v.RootHex)
	}
	if got := hex.EncodeToString(workerKey(root, v.Service)); got != v.Keys.WorkerHex {
		t.Errorf("worker key for %s = %s, the vector file records %s", v.Service, got, v.Keys.WorkerHex)
	}

	for _, text := range v.RootText.Valid {
		if got, ok := decodeHexKey(text); !ok || hex.EncodeToString(got) != strings.ToLower(v.RootHex) {
			t.Errorf("valid root text %q decodes to %x, %v", text, got, ok)
		}
	}
	for _, text := range v.RootText.Invalid {
		if _, ok := decodeHexKey(text); ok {
			t.Errorf("invalid root text %q decodes", text)
		}
	}
}

// Every key ensureStackKeys adds to the shipped .env.example lands on the
// line the template documents it on, so nothing is appended below the
// template's last section, and the result is the pair-consistent .env the
// stack boots from.
func TestRenderEnvFileShippedTemplate(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", ".env.example"))
	if err != nil {
		t.Fatalf("read shipped .env.example: %v", err)
	}

	rendered := renderEnvFile(string(raw), "example.com", "me@example.com", "ops@example.com", true)
	for _, want := range []string{
		"\nCYFR_HOST=example.com\n",
		"\nCYFR_BEHIND_PROXY=true\n",
		"\nCADDY_ACME_EMAIL=ops@example.com\n",
		"\nCYFR_PLATFORM_ADMIN_EMAILS=me@example.com\n",
	} {
		if !strings.Contains(rendered, want) {
			t.Errorf("shipped template: renderEnvFile did not produce %q", strings.TrimSpace(want))
		}
	}

	got, changes, err := ensureStackKeys(rendered)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Count(got, "\n") != strings.Count(rendered, "\n") {
		t.Errorf("keys were appended to the shipped template instead of set on its lines")
	}
	var added []string
	for _, c := range changes {
		added = append(added, c.key)
	}
	if want := []string{secretKeyBaseVar, bridgeKeyVar, workerRootVar, serviceKeyVar, buildsURLVar, buildsKeyVar}; !slices.Equal(added, want) {
		t.Errorf("added %v, want %v", added, want)
	}
	assertStackPairs(t, got, defaultServiceID)

	env := filepath.Join(t.TempDir(), ".env")
	if err := os.WriteFile(env, []byte(got), 0600); err != nil {
		t.Fatal(err)
	}
	if profiles := composeProfiles(env); !slices.Equal(profiles, []string{"tls", buildsProfile}) {
		t.Errorf("a TLS project fresh from init runs profiles %v, want every profile", profiles)
	}
	if _, again, err := ensureStackKeys(got); err != nil || len(again) != 0 {
		t.Errorf("a second init changes %v (%v)", again, err)
	}
}

// assertStackPairs checks what init promises of a .env: every key well
// formed, the service key the one the root derives for serviceID, and the
// builds URL and key set together.
func assertStackPairs(t *testing.T, text, serviceID string) {
	t.Helper()
	f := parseEnvFile(text)
	hexKey := regexp.MustCompile(`^[0-9A-Fa-f]{64}$`)
	for _, key := range []string{bridgeKeyVar, workerRootVar, serviceKeyVar, buildsKeyVar} {
		if v, _ := f.value(key); !hexKey.MatchString(v) {
			t.Errorf("%s is %q, not 64 hexadecimal digits", key, v)
		}
	}
	if v, _ := f.value(secretKeyBaseVar); len(v) < 64 {
		t.Errorf("%s is %q", secretKeyBaseVar, v)
	}
	rootText, _ := f.value(workerRootVar)
	serviceKey, _ := f.value(serviceKeyVar)
	if root, ok := decodeHexKey(rootText); !ok || serviceKey != hex.EncodeToString(workerKey(root, serviceID)) {
		t.Errorf("%s does not derive from %s for %s", serviceKeyVar, workerRootVar, serviceID)
	}
	if url, _ := f.value(buildsURLVar); url != defaultBuildsURL {
		t.Errorf("%s is %q", buildsURLVar, url)
	}
}

// Each state of an existing .env, as the plan names them: init adds only the
// keys it lacks and only consistently, never rewrites a key present, and
// refuses — writing nothing — a service key without its root or one that
// does not derive from the root present.
func TestEnsureStackKeysOverAnExistingEnv(t *testing.T) {
	const root = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
	rootBytes, _ := decodeHexKey(root)
	opusKey := hex.EncodeToString(workerKey(rootBytes, "wrk_opus"))
	otherKey := hex.EncodeToString(workerKey(rootBytes, "wrk_other"))
	const buildsKey = "b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1"
	const base = "CYFR_SECRET_KEY_BASE=kept-secret-key-base-kept-secret-key-base-kept-secret-key-base-kept\nCYFR_MCP_BRIDGE_KEY=" + buildsKey + "\n"

	cases := []struct {
		name    string
		body    string
		added   []string
		kept    map[string]string // settings that must read exactly so afterwards
		service string
		refusal string // a fragment of the refusal, when init refuses
	}{
		{
			name:    "no root and no service key: both are minted, builds turned on",
			body:    base + "CYFR_WORKER_KEY=\nOPUS_SERVICE_KEY=\n",
			added:   []string{workerRootVar, serviceKeyVar, buildsURLVar, buildsKeyVar},
			service: "wrk_opus",
		},
		{
			name:    "a root and no service key: the key is derived from that root",
			body:    base + "CYFR_WORKER_KEY=" + root + "\n# OPUS_SERVICE_KEY=\n",
			added:   []string{serviceKeyVar, buildsURLVar, buildsKeyVar},
			kept:    map[string]string{workerRootVar: root},
			service: "wrk_opus",
		},
		{
			name:    "a root spelled in capitals derives the same key",
			body:    base + "CYFR_WORKER_KEY=\"" + strings.ToUpper(root) + "\"\n",
			added:   []string{serviceKeyVar, buildsURLVar, buildsKeyVar},
			kept:    map[string]string{workerRootVar: strings.ToUpper(root)},
			service: "wrk_opus",
		},
		{
			name:    "a service id .env names is the one the key derives for",
			body:    base + "CYFR_WORKER_KEY=" + root + "\nOPUS_SERVICE_ID=wrk_other\n",
			added:   []string{serviceKeyVar, buildsURLVar, buildsKeyVar},
			kept:    map[string]string{serviceKeyVar: otherKey},
			service: "wrk_other",
		},
		{
			name:    "a consistent pair is kept as it is",
			body:    base + "CYFR_WORKER_KEY=" + root + "\nOPUS_SERVICE_KEY=" + opusKey + "\n",
			added:   []string{buildsURLVar, buildsKeyVar},
			kept:    map[string]string{workerRootVar: root, serviceKeyVar: opusKey},
			service: "wrk_opus",
		},
		{
			name:    "a service key without a root is refused",
			body:    base + "CYFR_WORKER_KEY=\nOPUS_SERVICE_KEY=" + opusKey + "\n",
			refusal: "OPUS_SERVICE_KEY is set in .env but CYFR_WORKER_KEY, the root it is derived from, is not",
		},
		{
			name:    "a service key another root derives is refused",
			body:    base + "CYFR_WORKER_KEY=" + strings.Repeat("ab", 32) + "\nOPUS_SERVICE_KEY=" + opusKey + "\n",
			refusal: "OPUS_SERVICE_KEY in .env is not the key CYFR_WORKER_KEY derives for OPUS_SERVICE_ID wrk_opus",
		},
		{
			name:    "a service key derived for another service id is refused",
			body:    base + "CYFR_WORKER_KEY=" + root + "\nOPUS_SERVICE_ID=wrk_other\nOPUS_SERVICE_KEY=" + opusKey + "\n",
			refusal: "for OPUS_SERVICE_ID wrk_other",
		},
		{
			name:    "a malformed service key is refused",
			body:    base + "CYFR_WORKER_KEY=" + root + "\nOPUS_SERVICE_KEY=abc\n",
			refusal: "is not the key CYFR_WORKER_KEY derives",
		},
		{
			name:    "a malformed root is refused",
			body:    base + "CYFR_WORKER_KEY=" + root[:63] + "\n",
			refusal: "CYFR_WORKER_KEY in .env is not 64 hexadecimal digits",
		},
		{
			name:    "a malformed service id is refused",
			body:    base + "OPUS_SERVICE_ID=opus\n",
			refusal: "OPUS_SERVICE_ID in .env is \"opus\"",
		},
		{
			name:    "a root assigned twice is refused",
			body:    base + "CYFR_WORKER_KEY=\nCYFR_WORKER_KEY=" + root + "\n",
			refusal: "CYFR_WORKER_KEY is assigned on 2 lines of .env",
		},
		{
			name:    "a builds key without a URL gets the URL",
			body:    base + "CYFR_WORKER_KEY=" + root + "\nOPUS_SERVICE_KEY=" + opusKey + "\nCYFR_LOCUS_BUILDS_KEY=" + buildsKey + "\n",
			added:   []string{buildsURLVar},
			kept:    map[string]string{buildsKeyVar: buildsKey},
			service: "wrk_opus",
		},
		{
			name:    "a builds URL without a key gets a minted key",
			body:    base + "CYFR_WORKER_KEY=" + root + "\nOPUS_SERVICE_KEY=" + opusKey + "\nCYFR_LOCUS_BUILDS_URL=http://locus-builds:4100\nCYFR_LOCUS_BUILDS_KEY=\n",
			added:   []string{buildsKeyVar},
			service: "wrk_opus",
		},
		{
			name:  "a builds URL set empty with no key is builds turned off, and left so",
			body:  base + "CYFR_WORKER_KEY=" + root + "\nOPUS_SERVICE_KEY=" + opusKey + "\nCYFR_LOCUS_BUILDS_URL=\nCYFR_LOCUS_BUILDS_KEY=\n",
			added: nil,
			kept:  map[string]string{buildsURLVar: "", buildsKeyVar: ""},
		},
		{
			name:    "no line for any key: each is appended",
			body:    "CYFR_HOST=localhost",
			added:   []string{secretKeyBaseVar, bridgeKeyVar, workerRootVar, serviceKeyVar, buildsURLVar, buildsKeyVar},
			kept:    map[string]string{"CYFR_HOST": "localhost"},
			service: "wrk_opus",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, changes, err := ensureStackKeys(tc.body)
			if tc.refusal != "" {
				if err == nil || !strings.Contains(err.Error(), tc.refusal) || !strings.HasSuffix(err.Error(), ".env is unchanged.") {
					t.Fatalf("want a refusal saying %q, got %v", tc.refusal, err)
				}
				if got != "" || changes != nil {
					t.Errorf("a refusal wrote %q, %v", got, changes)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			var added []string
			for _, c := range changes {
				added = append(added, c.key)
			}
			if !slices.Equal(added, tc.added) {
				t.Errorf("added %v, want %v", added, tc.added)
			}
			f := parseEnvFile(got)
			for key, want := range tc.kept {
				if v, _ := f.value(key); want != "" && v != want {
					t.Errorf("%s changed to %q", key, v)
				}
			}
			for key := range tc.kept {
				if len(f.assignments(key)) > 1 {
					t.Errorf("%s is assigned twice", key)
				}
			}
			if tc.service != "" {
				assertStackPairs(t, got, tc.service)
			}
			// Every line of the input that init had no key to write on is
			// still there, unchanged.
			for _, line := range strings.Split(tc.body, "\n") {
				if !strings.Contains(got, line) && !strings.HasSuffix(line, "=") && !strings.HasPrefix(line, "#") {
					t.Errorf("line %q was rewritten", line)
				}
			}
		})
	}
}

// At the file: a refused .env is left byte for byte, and one init
// completes keeps its mode and every line init had no key for.
func TestEnsureEnvFileKeys(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, ".env")

	refused := "# mine\nCYFR_WORKER_KEY=\nOPUS_SERVICE_KEY=" + strings.Repeat("ab", 32) + "\n"
	if err := os.WriteFile(path, []byte(refused), 0640); err != nil {
		t.Fatal(err)
	}
	if _, err := ensureEnvFileKeys(path); err == nil {
		t.Fatal("a service key without its root was accepted")
	}
	if got, _ := os.ReadFile(path); string(got) != refused {
		t.Errorf("a refused .env was written:\n%s", got)
	}

	partial := "# mine\nCYFR_HOST=cyfr.example.com\nCYFR_WORKER_KEY=\n"
	if err := os.WriteFile(path, []byte(partial), 0640); err != nil {
		t.Fatal(err)
	}
	changes, err := ensureEnvFileKeys(path)
	if err != nil || len(changes) == 0 {
		t.Fatalf("changes %v, %v", changes, err)
	}
	got, _ := os.ReadFile(path)
	if !strings.HasPrefix(string(got), "# mine\nCYFR_HOST=cyfr.example.com\nCYFR_WORKER_KEY=") {
		t.Errorf("the file's own lines moved:\n%s", got)
	}
	assertStackPairs(t, string(got), defaultServiceID)
	if info, _ := os.Stat(path); info.Mode().Perm() != 0640 {
		t.Errorf("mode %v, want 0640", info.Mode().Perm())
	}

	// Complete, it is not written again.
	before, _ := os.Stat(path)
	if changes, err := ensureEnvFileKeys(path); err != nil || len(changes) != 0 {
		t.Errorf("a complete .env changed: %v, %v", changes, err)
	}
	if after, _ := os.Stat(path); !after.ModTime().Equal(before.ModTime()) {
		t.Error("a complete .env was rewritten")
	}
	if leftovers, _ := filepath.Glob(filepath.Join(dir, ".*.tmp-*")); len(leftovers) != 0 {
		t.Errorf("temporary files left behind: %v", leftovers)
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
