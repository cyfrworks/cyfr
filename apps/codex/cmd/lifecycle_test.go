// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"testing"

	"github.com/cyfr/codex/internal/reach"
	"github.com/cyfr/codex/internal/release"
	"github.com/cyfr/codex/internal/scaffold"
	"github.com/sigstore/sigstore-go/pkg/root"
)

// renderEnvFile answers init's email question in the template: an email
// uncomments the operators' line with it and leaves the setup token's
// commented; no email sets the setup token's line. Nothing else changes.
func TestRenderEnvFile(t *testing.T) {
	tmpl := "CYFR_SECRET_KEY_BASE=\nCYFR_REACH=local\nCYFR_HOST=localhost\n# CYFR_PLATFORM_ADMIN_EMAILS=alice@example.com\n# CYFR_SETUP_TOKEN=\nCYFR_PORT=4000\n"
	token := strings.Repeat("ab", 32)

	got := renderEnvFile(tmpl, "me@example.com", "")
	if want := "CYFR_SECRET_KEY_BASE=\nCYFR_REACH=local\nCYFR_HOST=localhost\nCYFR_PLATFORM_ADMIN_EMAILS=me@example.com\n# CYFR_SETUP_TOKEN=\nCYFR_PORT=4000\n"; got != want {
		t.Errorf("with an email:\n%s\nwant\n%s", got, want)
	}
	got = renderEnvFile(tmpl, "", token)
	if want := "CYFR_SECRET_KEY_BASE=\nCYFR_REACH=local\nCYFR_HOST=localhost\n# CYFR_PLATFORM_ADMIN_EMAILS=alice@example.com\nCYFR_SETUP_TOKEN=" + token + "\nCYFR_PORT=4000\n"; got != want {
		t.Errorf("with no email:\n%s\nwant\n%s", got, want)
	}
	if strings.Contains(got, "PORTA") {
		t.Errorf("no porta variable belongs in .env:\n%s", got)
	}
}

// A generated key is 32 random bytes as 64 lowercase hexadecimal digits,
// the form cyfr, the worker and both Locus services all accept, and
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
// vector file of Prima.WorkerAuth, that the CLI's derivation consumes.
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

// The service key init writes is Prima.WorkerAuth.worker_key/2's: the value
// the vector file records for its root and service, and the root is read
// as the platform reads CYFR_LOCUS_RUNTIME_ROOT.
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

// packageDir is the package's own directory, the working directory tests
// start in, from which the repository's files are found whatever
// directory a test has moved into.
var packageDir, _ = os.Getwd()

// readShippedTemplate reads the .env.example `cyfr init` downloads.
func readShippedTemplate(t *testing.T) string {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join(packageDir, "..", "..", "..", ".env.example"))
	if err != nil {
		t.Fatalf("read shipped .env.example: %v", err)
	}
	return string(raw)
}

// The shipped template documents every line init writes, so each lands on
// it: the operators' line and the setup token's commented once each and
// nowhere assigned, the local head's keys assigned once each, no key of
// another mode's head assigned and no retired name anywhere. And each key
// ensureStackKeys writes is assigned there once, empty, or with the value
// init completes (the builds URL), so init writes every one on its own line.
func TestShippedTemplateCarriesInitsAnchors(t *testing.T) {
	text := readShippedTemplate(t)
	lines := strings.Split(text, "\n")
	count := func(prefix string) int {
		n := 0
		for _, line := range lines {
			if strings.HasPrefix(line, prefix) {
				n++
			}
		}
		return n
	}
	for _, key := range []string{adminEmailVar, setupTokenVar} {
		if n := count("# " + key + "="); n != 1 {
			t.Errorf("the shipped template has %d lines beginning %q, want 1", n, "# "+key+"=")
		}
		if n := count(key + "="); n != 0 {
			t.Errorf("the shipped template assigns %s on %d lines; init writes it on its commented line", key, n)
		}
	}

	f := parseEnvFile(text)
	for key, want := range map[string]string{"CYFR_REACH": "local", "CYFR_HOST": "localhost", "CYFR_PORT": "4000"} {
		if v, assigned := f.value(key); !assigned || v != want || len(f.assignments(key)) != 1 {
			t.Errorf("the shipped template's %s is %q (assigned: %v, on %d lines), want %s on one line", key, v, assigned, len(f.assignments(key)), want)
		}
	}
	for _, key := range []string{"CYFR_PUBLIC_URL", "CYFR_TAILNET_NODE_ID", "CADDY_ACME_EMAIL"} {
		if _, assigned := f.value(key); assigned {
			t.Errorf("the shipped template assigns %s, which a local home's head omits", key)
		}
	}
	if strings.Contains(text, retiredProxySetting) {
		t.Errorf("the shipped template names the retired %s", retiredProxySetting)
	}
	for _, key := range []string{secretKeyBaseVar, backendsKeyVar, workerRootVar, serviceKeyVar, buildsKeyVar, corsOriginsVar} {
		if v, assigned := f.value(key); !assigned || v != "" || len(f.assignments(key)) != 1 {
			t.Errorf("the shipped template does not assign %s empty on one line (%q, assigned: %v)", key, v, assigned)
		}
	}
	if v, _ := f.value(buildsURLVar); v != defaultBuildsURL || len(f.assignments(buildsURLVar)) != 1 {
		t.Errorf("the shipped template's %s is %q, want %s on one line", buildsURLVar, v, defaultBuildsURL)
	}
	if _, assigned := f.value(serviceIDVar); assigned {
		t.Errorf("the shipped template assigns %s; compose's default names the locus-runtime service", serviceIDVar)
	}
}

// newEnvFromTemplate is the .env init writes from the shipped template for
// adminEmail, or with the setup token token when there is none: the keys
// minted, then the local head written.
func newEnvFromTemplate(t *testing.T, adminEmail, token string) (string, []envChange) {
	t.Helper()
	rendered := renderEnvFile(readShippedTemplate(t), adminEmail, token)
	text, changes, err := ensureStackKeys(rendered)
	if err != nil {
		t.Fatal(err)
	}
	f := parseEnvFile(text)
	d, err := localHead(f)
	if err != nil {
		t.Fatal(err)
	}
	writeHead(f, d)
	return f.String(), changes
}

// Every key init writes into the shipped .env.example lands on the line the
// template documents it on, so nothing is appended below the template's
// last section, and the result is the pair-consistent .env, reached from
// this computer only, that the stack boots from.
func TestRenderEnvFileShippedTemplate(t *testing.T) {
	raw := readShippedTemplate(t)
	got, changes := newEnvFromTemplate(t, "me@example.com", "")
	if !strings.Contains(got, "\nCYFR_PLATFORM_ADMIN_EMAILS=me@example.com\n") || strings.Contains(got, "# CYFR_PLATFORM_ADMIN_EMAILS=") {
		t.Errorf("shipped template: the operators' line is not set:\n%s", got)
	}
	if strings.Count(got, "\n") != strings.Count(raw, "\n") {
		t.Errorf("keys were appended to the shipped template instead of set on its lines")
	}
	var added []string
	for _, c := range changes {
		added = append(added, c.key)
	}
	// The template carries the builds URL; init mints the key beside it.
	if want := []string{secretKeyBaseVar, backendsKeyVar, workerRootVar, serviceKeyVar, buildsKeyVar}; !slices.Equal(added, want) {
		t.Errorf("added %v, want %v", added, want)
	}
	assertStackPairs(t, got, defaultServiceID)

	// The template assigns the empty allowlist itself, so `cp .env.example
	// .env` boots a release too; init has nothing to add and leaves it.
	f := parseEnvFile(got)
	if cors, assigned := f.value(corsOriginsVar); !assigned || cors != "" {
		t.Errorf("the shipped template's %s is %q (assigned: %v)", corsOriginsVar, cors, assigned)
	}
	if token, assigned := f.value(setupTokenVar); assigned {
		t.Errorf("a home given its operator's email holds the setup token %q", token)
	}

	env := envAssignments(writeTemp(t, ".env", got))
	boot, err := reach.ResolveBoot(reach.BootInput{File: env, Process: env, Release: true})
	if err != nil {
		t.Fatalf("the .env init writes does not boot: %v", engineFailure(err))
	}
	if boot.Head.Mode != reach.ModeLocal || boot.Origin != "http://localhost:4000" || !slices.Equal(boot.Head.Profiles, []string{buildsProfile}) {
		t.Errorf("a project fresh from init is reached as %+v at %s, want local at http://localhost:4000 with builds on", boot.Head, boot.Origin)
	}
	if _, again, err := ensureStackKeys(got); err != nil || len(again) != 0 {
		t.Errorf("a second init changes %v (%v)", again, err)
	}
}

// writeTemp writes text to a file named name in a directory of the test's
// own and answers its path.
func writeTemp(t *testing.T, name, text string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(path, []byte(text), 0600); err != nil {
		t.Fatal(err)
	}
	return path
}

// A home init gives an address is answered at that address: the .env it
// writes for a public name names the https origin the name implies, the
// one Sanctum.origin/0 and every policy derived from it read. Through init
// itself and the reach engine's switch of the stopped stack.
func TestInitWritesThePublicURLItsAddressImplies(t *testing.T) {
	newInitProject(t)
	useRealEngine(t, &stoppedDocker{})
	var out bytes.Buffer
	err := runInit(context.Background(), initOptions{mode: reach.ModePublic, reachOptions: reachOptions{domain: "cyfr.example.com"}, noPull: true}, &out, &out)
	if err != nil {
		t.Fatalf("cyfr init: %v\n%s", err, out.String())
	}
	got, err := os.ReadFile(".env")
	if err != nil {
		t.Fatal(err)
	}
	if url, assigned := parseEnvFile(string(got)).value("CYFR_PUBLIC_URL"); !assigned || url != "https://cyfr.example.com" {
		t.Errorf("init for cyfr.example.com writes CYFR_PUBLIC_URL %q (assigned: %v), want https://cyfr.example.com", url, assigned)
	}
}

// Given no email, init mints the setup token onto the template's line:
// 64 lowercase hexadecimal characters, the operators' line left commented,
// nothing appended, and the .env boots.
func TestRenderEnvFileShippedTemplateWithoutAnEmail(t *testing.T) {
	raw := readShippedTemplate(t)
	token, err := generateHexKey()
	if err != nil {
		t.Fatal(err)
	}
	got, _ := newEnvFromTemplate(t, "", token)
	f := parseEnvFile(got)
	if v, _ := f.value(setupTokenVar); v != token || !setupTokenPattern.MatchString(v) {
		t.Errorf("the setup token is %q, want %q", v, token)
	}
	if !strings.Contains(got, "\n"+"# "+adminEmailVar+"=\n") {
		t.Errorf("the operators' line is not left commented:\n%s", got)
	}
	if strings.Count(got, "\n") != strings.Count(raw, "\n") {
		t.Errorf("the token was appended instead of set on its line")
	}
	assertStackPairs(t, got, defaultServiceID)
}

// assertStackPairs checks what init promises of a .env: every key well
// formed, the service key the one the root derives for serviceID, and the
// builds URL and key set together.
func assertStackPairs(t *testing.T, text, serviceID string) {
	t.Helper()
	f := parseEnvFile(text)
	hexKey := regexp.MustCompile(`^[0-9A-Fa-f]{64}$`)
	for _, key := range []string{backendsKeyVar, workerRootVar, serviceKeyVar, buildsKeyVar} {
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
	// Unassigned, the application's configured list stands, which a
	// deployment's own configuration may set; a wildcard here would open the
	// door a release with sign-in configured refuses to boot behind.
	cors, assigned := f.value(corsOriginsVar)
	if !assigned {
		t.Errorf("%s is not assigned, so the wildcard default stands", corsOriginsVar)
	}
	if strings.Contains(cors, "*") {
		t.Errorf("%s is %q", corsOriginsVar, cors)
	}
}

// Each state of an existing .env, as the plan names them: init adds only the
// keys it lacks and only consistently, never rewrites a key present, and
// refuses — writing nothing — a service key without its root or one that
// does not derive from the root present.
func TestEnsureStackKeysOverAnExistingEnv(t *testing.T) {
	const root = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
	rootBytes, _ := decodeHexKey(root)
	runtimeKey := hex.EncodeToString(workerKey(rootBytes, "wrk_locus"))
	otherKey := hex.EncodeToString(workerKey(rootBytes, "wrk_other"))
	const buildsKey = "b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1"
	const base = "CYFR_SECRET_KEY_BASE=kept-secret-key-base-kept-secret-key-base-kept-secret-key-base-kept\nCYFR_LOCUS_BACKENDS_KEY=" + buildsKey + "\n"
	// builds is .env.example's builds URL, which builds are on with.
	const builds = "CYFR_LOCUS_BUILDS_URL=http://locus-builds:4100\n"

	cases := []struct {
		name    string
		body    string
		added   []string
		kept    map[string]string // settings that must read exactly so afterwards
		service string
		refusal string // a fragment of the refusal, when init refuses
	}{
		{
			name:    "no root and no service key: both are minted, and the builds key beside the URL",
			body:    base + builds + "CYFR_LOCUS_RUNTIME_ROOT=\nLOCUS_RUNTIME_KEY=\n",
			added:   []string{workerRootVar, serviceKeyVar, corsOriginsVar, buildsKeyVar},
			service: "wrk_locus",
		},
		{
			name:    "a root and no service key: the key is derived from that root",
			body:    base + builds + "CYFR_LOCUS_RUNTIME_ROOT=" + root + "\n# LOCUS_RUNTIME_KEY=\n",
			added:   []string{serviceKeyVar, corsOriginsVar, buildsKeyVar},
			kept:    map[string]string{workerRootVar: root},
			service: "wrk_locus",
		},
		{
			name:    "a root spelled in capitals derives the same key",
			body:    base + builds + "CYFR_LOCUS_RUNTIME_ROOT=\"" + strings.ToUpper(root) + "\"\n",
			added:   []string{serviceKeyVar, corsOriginsVar, buildsKeyVar},
			kept:    map[string]string{workerRootVar: strings.ToUpper(root)},
			service: "wrk_locus",
		},
		{
			name:    "a service id .env names is the one the key derives for",
			body:    base + builds + "CYFR_LOCUS_RUNTIME_ROOT=" + root + "\nLOCUS_RUNTIME_SERVICE_ID=wrk_other\n",
			added:   []string{serviceKeyVar, corsOriginsVar, buildsKeyVar},
			kept:    map[string]string{serviceKeyVar: otherKey},
			service: "wrk_other",
		},
		{
			name:    "a consistent pair is kept as it is",
			body:    base + builds + "CYFR_LOCUS_RUNTIME_ROOT=" + root + "\nLOCUS_RUNTIME_KEY=" + runtimeKey + "\n",
			added:   []string{corsOriginsVar, buildsKeyVar},
			kept:    map[string]string{workerRootVar: root, serviceKeyVar: runtimeKey},
			service: "wrk_locus",
		},
		{
			name:    "a service key without a root is refused",
			body:    base + "CYFR_LOCUS_RUNTIME_ROOT=\nLOCUS_RUNTIME_KEY=" + runtimeKey + "\n",
			refusal: "LOCUS_RUNTIME_KEY is set in .env but CYFR_LOCUS_RUNTIME_ROOT, the root it is derived from, is not",
		},
		{
			name:    "a service key another root derives is refused",
			body:    base + "CYFR_LOCUS_RUNTIME_ROOT=" + strings.Repeat("ab", 32) + "\nLOCUS_RUNTIME_KEY=" + runtimeKey + "\n",
			refusal: "LOCUS_RUNTIME_KEY in .env is not the key CYFR_LOCUS_RUNTIME_ROOT derives for LOCUS_RUNTIME_SERVICE_ID wrk_locus",
		},
		{
			name:    "a service key derived for another service id is refused",
			body:    base + "CYFR_LOCUS_RUNTIME_ROOT=" + root + "\nLOCUS_RUNTIME_SERVICE_ID=wrk_other\nLOCUS_RUNTIME_KEY=" + runtimeKey + "\n",
			refusal: "for LOCUS_RUNTIME_SERVICE_ID wrk_other",
		},
		{
			name:    "a malformed service key is refused",
			body:    base + "CYFR_LOCUS_RUNTIME_ROOT=" + root + "\nLOCUS_RUNTIME_KEY=abc\n",
			refusal: "is not the key CYFR_LOCUS_RUNTIME_ROOT derives",
		},
		{
			name:    "a malformed root is refused",
			body:    base + "CYFR_LOCUS_RUNTIME_ROOT=" + root[:63] + "\n",
			refusal: "CYFR_LOCUS_RUNTIME_ROOT in .env is not 64 hexadecimal digits",
		},
		{
			name:    "a malformed service id is refused",
			body:    base + "LOCUS_RUNTIME_SERVICE_ID=runtime\n",
			refusal: "LOCUS_RUNTIME_SERVICE_ID in .env is \"runtime\"",
		},
		{
			name:    "a root assigned twice is refused",
			body:    base + "CYFR_LOCUS_RUNTIME_ROOT=\nCYFR_LOCUS_RUNTIME_ROOT=" + root + "\n",
			refusal: "CYFR_LOCUS_RUNTIME_ROOT is assigned on 2 lines of .env",
		},
		{
			name:    "a builds key without a URL gets the URL",
			body:    base + "CYFR_LOCUS_RUNTIME_ROOT=" + root + "\nLOCUS_RUNTIME_KEY=" + runtimeKey + "\nCYFR_LOCUS_BUILDS_KEY=" + buildsKey + "\n",
			added:   []string{corsOriginsVar, buildsURLVar},
			kept:    map[string]string{buildsKeyVar: buildsKey},
			service: "wrk_locus",
		},
		{
			name:    "a builds URL without a key gets a minted key",
			body:    base + "CYFR_LOCUS_RUNTIME_ROOT=" + root + "\nLOCUS_RUNTIME_KEY=" + runtimeKey + "\nCYFR_LOCUS_BUILDS_URL=http://locus-builds:4100\nCYFR_LOCUS_BUILDS_KEY=\n",
			added:   []string{corsOriginsVar, buildsKeyVar},
			service: "wrk_locus",
		},
		{
			name:  "a builds URL set empty with no key is builds turned off, and left so",
			body:  base + "CYFR_LOCUS_RUNTIME_ROOT=" + root + "\nLOCUS_RUNTIME_KEY=" + runtimeKey + "\nCYFR_LOCUS_BUILDS_URL=\nCYFR_LOCUS_BUILDS_KEY=\n",
			added: []string{corsOriginsVar},
			kept:  map[string]string{buildsURLVar: "", buildsKeyVar: ""},
		},
		{
			name:  "an allowlist .env assigns is kept, empty or not",
			body:  base + "CYFR_LOCUS_RUNTIME_ROOT=" + root + "\nLOCUS_RUNTIME_KEY=" + runtimeKey + "\nCYFR_LOCUS_BUILDS_URL=\nCYFR_LOCUS_BUILDS_KEY=\nCYFR_CORS_ALLOWED_ORIGINS=https://app.example.com\n",
			added: nil,
			kept:  map[string]string{corsOriginsVar: "https://app.example.com"},
		},
		{
			name:  "no line for any key: each is appended, and no builds URL is builds off",
			body:  "CYFR_HOST=localhost",
			added: []string{secretKeyBaseVar, backendsKeyVar, workerRootVar, serviceKeyVar, corsOriginsVar},
			kept:  map[string]string{"CYFR_HOST": "localhost"},
		},
		{
			// A switch removes the reach key a head omits, the empty builds
			// URL among them; builds stay off.
			name:  "a builds URL a switch removed, with no key, is builds off and left so",
			body:  base + "CYFR_LOCUS_RUNTIME_ROOT=" + root + "\nLOCUS_RUNTIME_KEY=" + runtimeKey + "\nCYFR_LOCUS_BUILDS_KEY=\nCYFR_CORS_ALLOWED_ORIGINS=\n",
			added: nil,
			kept:  map[string]string{buildsKeyVar: ""},
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
			if url, _ := f.value(buildsURLVar); tc.service == "" && url != "" {
				t.Errorf("builds turned on (%s=%s)", buildsURLVar, url)
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

	refused := "# mine\nCYFR_LOCUS_RUNTIME_ROOT=\nLOCUS_RUNTIME_KEY=" + strings.Repeat("ab", 32) + "\n"
	if err := os.WriteFile(path, []byte(refused), 0640); err != nil {
		t.Fatal(err)
	}
	if _, err := ensureEnvFileKeys(path); err == nil {
		t.Fatal("a service key without its root was accepted")
	}
	if got, _ := os.ReadFile(path); string(got) != refused {
		t.Errorf("a refused .env was written:\n%s", got)
	}

	partial := "# mine\nCYFR_HOST=cyfr.example.com\nCYFR_LOCUS_RUNTIME_ROOT=\nCYFR_LOCUS_BUILDS_URL=http://locus-builds:4100\n"
	if err := os.WriteFile(path, []byte(partial), 0640); err != nil {
		t.Fatal(err)
	}
	// WriteFile's mode passes through the process umask (077 under
	// scripts/heavy-check.sh); the mode init must keep is set outright.
	if err := os.Chmod(path, 0640); err != nil {
		t.Fatal(err)
	}
	changes, err := ensureEnvFileKeys(path)
	if err != nil || len(changes) == 0 {
		t.Fatalf("changes %v, %v", changes, err)
	}
	got, _ := os.ReadFile(path)
	if !strings.HasPrefix(string(got), "# mine\nCYFR_HOST=cyfr.example.com\nCYFR_LOCUS_RUNTIME_ROOT=") {
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

// .env's replacement is written beside it as `..env.tmp-*` (writeFileAtomic,
// as the engine's durable write names it) and gone on every path a living
// process takes, a write that fails included; only a process that died
// inside the write leaves one, which the project's .gitignore ignores.
func TestEnvWritesLeaveNoTemporaryFile(t *testing.T) {
	dir := t.TempDir()
	if err := writeFileAtomic(filepath.Join(dir, ".env"), []byte("A=1\n"), 0600); err != nil {
		t.Fatal(err)
	}
	// A directory where .env goes: the rename fails after the temporary
	// file is written.
	if err := os.Mkdir(filepath.Join(dir, "sub"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(dir, "sub", ".env", "kept"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := writeFileAtomic(filepath.Join(dir, "sub", ".env"), []byte("A=1\n"), 0600); err == nil {
		t.Fatal("a write over a directory succeeded")
	}
	for _, d := range []string{dir, filepath.Join(dir, "sub")} {
		if left, _ := filepath.Glob(filepath.Join(d, "..env.tmp-*")); len(left) != 0 {
			t.Errorf("a write left %v", left)
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
    profiles: ["public"]
  locus-builds:
    image: ghcr.io/cyfrworks/cyfr-locus:latest
    profiles: ["locus-builds"]
  locus-backends:
    image: ghcr.io/cyfrworks/cyfr-locus:latest
  source-built:
    build:
      context: .
`
	if err := os.WriteFile(path, []byte(body), 0644); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		profiles []string
		want     []string
	}{
		{nil, []string{"ghcr.io/cyfrworks/cyfr:latest", "ghcr.io/cyfrworks/cyfr-locus:latest"}},
		{[]string{"locus-builds"}, []string{"ghcr.io/cyfrworks/cyfr:latest", "ghcr.io/cyfrworks/cyfr-locus:latest"}},
		{[]string{"locus-builds", "public"}, []string{"ghcr.io/cyfrworks/cyfr:latest", "caddy:2-alpine", "ghcr.io/cyfrworks/cyfr-locus:latest"}},
		{[]string{"other"}, []string{"ghcr.io/cyfrworks/cyfr:latest", "ghcr.io/cyfrworks/cyfr-locus:latest"}},
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

// The shipped compose file and .env.example: the cyfr-locus image is pulled
// for locus-backends, which always starts; a project that points builds at
// the locus-builds service selects its profile with the value .env.example
// offers, and the one image is pulled once for both services.
func TestShippedComposePullsTheLocusImageOnce(t *testing.T) {
	const image = "ghcr.io/cyfrworks/cyfr-locus:latest"
	compose := filepath.Join("..", "..", "..", "docker-compose.yml")
	count := func(images []string) int {
		n := 0
		for _, img := range images {
			if img == image {
				n++
			}
		}
		return n
	}
	if got := imagesFromCompose(compose, nil); count(got) != 1 {
		t.Errorf("without the builds profile the Locus image is not pulled once for locus-backends: %v", got)
	}

	var offered string
	for _, line := range strings.Split(readShippedTemplate(t), "\n") {
		if strings.HasPrefix(line, buildsURLVar+"=") {
			offered = line
		}
	}
	if offered == "" {
		t.Fatal(".env.example offers no CYFR_LOCUS_BUILDS_URL")
	}

	builds, _ := parseEnvFile(offered).value(buildsURLVar)
	profiles := reach.Profiles(reach.ModeLocal, builds)
	if !slices.Contains(profiles, buildsProfile) {
		t.Errorf("a project using the builds service (%s) does not select its profile: %v", offered, profiles)
	}
	if got := imagesFromCompose(compose, profiles); count(got) != 1 {
		t.Errorf("a project using the builds service (%s) does not pull the Locus image once: %v", offered, got)
	}
}

// `cyfr init --force` lays the tarball's deploy files down again, the
// keeper's seccomp profile among them as `cyfr update` refreshes it, so a
// forced init never keeps a profile older than the image it pulls; a dev
// build, whose tarball is a no-op, removes none.
func TestForceRefetchesTheSeccompProfile(t *testing.T) {
	got := forceRefetched(true)
	for _, want := range []string{"docker-compose.yml", "Caddyfile", scaffold.SeccompProfile} {
		if !slices.Contains(got, want) {
			t.Errorf("init --force re-fetches %v, which lacks %s", got, want)
		}
	}
	for _, kept := range []string{".env", ".env.example", "cyfr.yaml"} {
		if slices.Contains(got, kept) {
			t.Errorf("init --force re-fetches %s, which it must keep", kept)
		}
	}
	if dev := forceRefetched(false); len(dev) != 0 {
		t.Errorf("a dev build's init --force removes %v, which its no-op tarball cannot replace", dev)
	}
}

// `cyfr init` stops when the scaffold of its release fails verification,
// naming the release and that nothing was extracted, and goes on with a
// warning when the download itself fails.
func TestScaffoldDownloadFailure(t *testing.T) {
	var warn bytes.Buffer
	unverified := fmt.Errorf("checksums.txt for 1.2.3: %w: not signed by the release workflow", release.ErrUnverified)
	err := scaffoldDownloadFailure("1.2.3", unverified, &warn)
	if err == nil {
		t.Fatal("an unverified scaffold lets init continue")
	}
	if !errors.Is(err, release.ErrUnverified) || !strings.Contains(err.Error(), "1.2.3") || !strings.Contains(err.Error(), "nothing was extracted") {
		t.Errorf("the refusal is %q", err)
	}
	if warn.Len() != 0 {
		t.Errorf("a refusal also warned %q", warn.String())
	}

	transport := errors.New("checksums.txt: download https://example.invalid/checksums.txt: HTTP 503")
	if err := scaffoldDownloadFailure("1.2.3", transport, &warn); err != nil {
		t.Errorf("a transport failure stops init: %v", err)
	}
	if !strings.Contains(warn.String(), "HTTP 503") || !strings.Contains(warn.String(), "continuing anyway") {
		t.Errorf("a transport failure warns %q", warn.String())
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

type roundTripper func(*http.Request) (*http.Response, error)

func (f roundTripper) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

// `cyfr init` stops on a scaffold its release's signed checksums.txt does
// not name, rather than warn and go on to an unpinned warm pull: the real
// download path, under the vector file's test trust root, answers a
// verification failure, and init reads it as one. Found by review: the
// mismatch read as a transport failure.
func TestInitRefusesAlteredScaffold(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "tests", "fixtures", "release_manifest.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Signature struct {
			TrustedRoot json.RawMessage `json:"trusted_root"`
			Checksums   struct {
				Version   string          `json:"version"`
				Checksums string          `json:"checksums"`
				Bundle    json.RawMessage `json:"bundle"`
			} `json:"checksums"`
		} `json:"signature"`
	}
	if err := json.Unmarshal(raw, &fixture); err != nil {
		t.Fatal(err)
	}
	trusted, err := root.NewTrustedRootFromJSON(fixture.Signature.TrustedRoot)
	if err != nil {
		t.Fatal(err)
	}
	savedTrust, savedTransport := release.TrustMaterial, http.DefaultTransport
	t.Cleanup(func() { release.TrustMaterial, http.DefaultTransport = savedTrust, savedTransport })
	release.TrustMaterial = func(context.Context) (root.TrustedMaterial, error) { return trusted, nil }
	checksums := fixture.Signature.Checksums
	http.DefaultTransport = roundTripper(func(r *http.Request) (*http.Response, error) {
		var content string
		switch filepath.Base(r.URL.Path) {
		case "checksums.txt":
			content = checksums.Checksums
		case "checksums.txt.sigstore.json":
			content = string(checksums.Bundle)
		case "cyfr-scaffold.tar.gz":
			content = "tampered scaffold"
		default:
			return nil, fmt.Errorf("unexpected request: %s", r.URL)
		}
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(content)), Header: make(http.Header), Request: r}, nil
	})
	t.Chdir(t.TempDir())

	downloadErr := scaffold.Download(checksums.Version)
	if downloadErr == nil || !strings.Contains(downloadErr.Error(), "checksum mismatch") {
		t.Fatalf("expected the checksum mismatch, got %v", downloadErr)
	}
	var warning bytes.Buffer
	if stop := scaffoldDownloadFailure(checksums.Version, downloadErr, &warning); stop == nil {
		t.Fatalf("init continued after the signed checksums.txt refused the tarball: %v; warning=%q", downloadErr, warning.String())
	}
	if warning.Len() != 0 {
		t.Errorf("init warned %q and stopped; a verification failure is no warning", warning.String())
	}
}

// `cyfr init` ignores the snapshots `cyfr update` takes under backups/,
// each of which holds the keyring and the database, and the reach engine's
// state under .cyfr/, beside the runtime state and the environment files.
func TestInitIgnoresTheSnapshots(t *testing.T) {
	t.Chdir(t.TempDir())
	fake := t.TempDir()
	if err := os.WriteFile(filepath.Join(fake, "docker"), []byte("#!/bin/sh\nexit 0\n"), 0755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", fake+string(os.PathListSeparator)+os.Getenv("PATH"))
	if err := initCmd.RunE(initCmd, nil); err != nil {
		t.Fatalf("cyfr init: %v", err)
	}
	got, err := os.ReadFile(".gitignore")
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(string(got), "\n")
	for _, want := range []string{"/backups/", "/data/", "/.cyfr/", ".env", ".env.local", ".env.*.local", "..env.tmp-*"} {
		if !slices.Contains(lines, want) {
			t.Errorf(".gitignore lacks %s:\n%s", want, got)
		}
	}
}

// `cyfr init --force` that cannot remove a file it re-fetches or
// regenerates refuses, naming the file, instead of keeping the old one and
// reporting the project ready.
func TestInitForceRefusesAFileItCannotRemove(t *testing.T) {
	t.Chdir(t.TempDir())
	fake := t.TempDir()
	if err := os.WriteFile(filepath.Join(fake, "docker"), []byte("#!/bin/sh\nexit 0\n"), 0755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", fake+string(os.PathListSeparator)+os.Getenv("PATH"))
	// A directory with an entry in it: no remove takes it, whoever runs.
	if err := os.MkdirAll(filepath.Join("cyfr.yaml", "kept"), 0755); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { initCmd.Flags().Set("force", "false") })
	if err := initCmd.Flags().Set("force", "true"); err != nil {
		t.Fatal(err)
	}
	err := initCmd.RunE(initCmd, nil)
	if err == nil || !strings.Contains(err.Error(), "could not remove cyfr.yaml") || !strings.Contains(err.Error(), "cyfr init --force") {
		t.Fatalf("cyfr init --force answered %v", err)
	}
	if info, statErr := os.Stat("cyfr.yaml"); statErr != nil || !info.IsDir() {
		t.Errorf("cyfr.yaml is %v (%v), want the directory left as it was", info, statErr)
	}
}
