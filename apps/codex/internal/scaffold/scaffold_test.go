// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package scaffold

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io/fs"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/cyfr/codex/internal/release"
	"github.com/sigstore/sigstore-go/pkg/root"
)

// TestIsManaged pins down which scaffold entries `cyfr update` is allowed to
// overwrite. Managed = the guides, the WIT definitions, and the AQUA files
// the scaffold ships — the soul, the shipped roles and every file inside a
// shipped scroll. Everything a member owns — config, the compose/proxy
// files, their own roles and scrolls, .env — must NOT be managed, or
// `cyfr update` would clobber them.
func TestIsManaged(t *testing.T) {
	managed := []string{
		"configuration-guide.md",
		"component-guide.md",
		"tincture-guide.md",
		"integration-guide.md",
		"identity-guide.md",
		"devices-guide.md",
		"keeper.seccomp.json",
		"wit",
		"wit/cyfr/oauth/token.wit",
		"aqua/aqua.md",
		"aqua/roles/builder.md",
		"aqua/roles/web.md",
		"aqua/skills/canvas/SKILL.md",
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
		".env.locus.example",
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

// TestShippedGuidesAreManaged binds the guides the scaffold tarball packs
// (scripts/scaffold-tarball.sh's items) to Guides and to the managed set: a
// guide shipped but not managed would never be refreshed by `cyfr update`,
// and one managed but not shipped would name nothing. Every guide at the
// repository's root ships, so a new root guide fails here until it is
// listed.
func TestShippedGuidesAreManaged(t *testing.T) {
	root := filepath.Join("..", "..", "..", "..")
	raw, err := os.ReadFile(filepath.Join(root, "scripts", "scaffold-tarball.sh"))
	if err != nil {
		t.Fatalf("read scaffold-tarball.sh: %v", err)
	}
	items := regexp.MustCompile(`(?s)\nITEMS=\((.*?)\n\)`).FindStringSubmatch(string(raw))
	if items == nil {
		t.Fatal("scaffold-tarball.sh has no ITEMS list")
	}
	var shipped []string
	for _, line := range strings.Split(items[1], "\n") {
		if strings.HasPrefix(strings.TrimSpace(line), "#") {
			continue
		}
		for _, item := range strings.Fields(line) {
			if strings.HasSuffix(item, "-guide.md") {
				shipped = append(shipped, item)
			}
		}
	}
	want := slices.Clone(Guides)
	slices.Sort(want)
	slices.Sort(shipped)
	if !slices.Equal(shipped, want) {
		t.Errorf("the tarball ships the guides %v, and Guides names %v", shipped, want)
	}
	for _, guide := range shipped {
		if !isManaged(guide) {
			t.Errorf("the tarball ships %s, which `cyfr update` does not refresh", guide)
		}
	}
	paths, err := filepath.Glob(filepath.Join(root, "*-guide.md"))
	if err != nil {
		t.Fatalf("glob the root guides: %v", err)
	}
	var present []string
	for _, path := range paths {
		present = append(present, filepath.Base(path))
	}
	slices.Sort(present)
	if !slices.Equal(present, want) {
		t.Errorf("the repository's root guides are %v, and Guides names %v", present, want)
	}
}

// TestShippedProfileIsManaged binds the seccomp profile the scaffold tarball
// packs beside docker-compose.yml to the managed set and to the name the
// locus-runtime service gives it: a profile shipped but not managed would stay
// behind the image `cyfr update` pulls, and one named otherwise than the
// compose file names it would never be read.
func TestShippedProfileIsManaged(t *testing.T) {
	root := filepath.Join("..", "..", "..", "..")
	raw, err := os.ReadFile(filepath.Join(root, "scripts", "scaffold-tarball.sh"))
	if err != nil {
		t.Fatalf("read scaffold-tarball.sh: %v", err)
	}
	script := string(raw)
	source := regexp.MustCompile(`(?m)^PROFILE=(\S+)$`).FindStringSubmatch(script)
	name := regexp.MustCompile(`(?m)^PROFILE_NAME=(\S+)$`).FindStringSubmatch(script)
	if source == nil || name == nil {
		t.Fatal("scaffold-tarball.sh names no PROFILE and PROFILE_NAME")
	}
	if source[1] != "apps/locus/keeper/seccomp/keeper.json" || name[1] != SeccompProfile {
		t.Errorf("the tarball ships %s as %s, want apps/locus/keeper/seccomp/keeper.json as %s", source[1], name[1], SeccompProfile)
	}
	if !strings.Contains(script, `-C "$STAGE" "$PROFILE_NAME"`) {
		t.Error("scaffold-tarball.sh does not pack the staged profile")
	}
	if _, err := os.Stat(filepath.Join(root, source[1])); err != nil {
		t.Errorf("the profile the tarball ships: %v", err)
	}
	if !isManaged(SeccompProfile) {
		t.Errorf("the tarball ships %s, which `cyfr update` does not refresh", SeccompProfile)
	}
	compose, err := os.ReadFile(filepath.Join(root, "docker-compose.yml"))
	if err != nil {
		t.Fatalf("read docker-compose.yml: %v", err)
	}
	if !strings.Contains(string(compose), "      - seccomp=./"+SeccompProfile+"\n") {
		t.Errorf("docker-compose.yml does not name ./%s", SeccompProfile)
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

// signedChecksums is the vector file's signed checksums.txt: the release it
// is signed for, its exact bytes, its bundle, the scaffold tarball its line
// names and the test instance's trusted root.
type signedChecksums struct {
	version   string
	checksums []byte
	bundle    []byte
	tarball   []byte
	trusted   root.TrustedMaterial
}

func readSignedChecksums(t *testing.T) signedChecksums {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "..", "tests", "fixtures", "release_manifest.json"))
	if err != nil {
		t.Fatalf("read the vector file: %v", err)
	}
	var f struct {
		Signature struct {
			TrustedRoot json.RawMessage `json:"trusted_root"`
			Checksums   struct {
				Version   string          `json:"version"`
				Checksums string          `json:"checksums"`
				Bundle    json.RawMessage `json:"bundle"`
				Tarball   []byte          `json:"tarball"`
			} `json:"checksums"`
		} `json:"signature"`
	}
	if err := json.Unmarshal(raw, &f); err != nil {
		t.Fatalf("parse the vector file: %v", err)
	}
	c := f.Signature.Checksums
	if c.Version == "" || c.Checksums == "" || len(c.Bundle) == 0 || len(c.Tarball) == 0 {
		t.Fatal("the vector file has no signed checksums.txt")
	}
	trusted, err := root.NewTrustedRootFromJSON(f.Signature.TrustedRoot)
	if err != nil {
		t.Fatalf("the vector file's trusted root: %v", err)
	}
	return signedChecksums{c.Version, []byte(c.Checksums), c.Bundle, c.Tarball, trusted}
}

// serveScaffold serves a release's scaffold assets under /<version>/ from
// a fresh working directory, with the vector file's test instance as the
// trust root, and counts the tarball's downloads.
func serveScaffold(t *testing.T, sc signedChecksums, version string, assets map[string][]byte) *atomic.Int64 {
	t.Helper()
	var tarballGets atomic.Int64
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		name := strings.TrimPrefix(r.URL.Path, "/"+version+"/")
		if name == "cyfr-scaffold.tar.gz" {
			tarballGets.Add(1)
		}
		body, ok := assets[name]
		if !ok || name == r.URL.Path {
			http.NotFound(w, r)
			return
		}
		_, _ = w.Write(body)
	}))
	t.Cleanup(srv.Close)

	savedURL, savedChecksums, savedTrust := urlTemplate, checksumTemplate, release.TrustMaterial
	t.Cleanup(func() { urlTemplate, checksumTemplate, release.TrustMaterial = savedURL, savedChecksums, savedTrust })
	urlTemplate = srv.URL + "/%s/cyfr-scaffold.tar.gz"
	checksumTemplate = srv.URL + "/%s/checksums.txt"
	release.TrustMaterial = func(context.Context) (root.TrustedMaterial, error) { return sc.trusted, nil }

	t.Chdir(t.TempDir())
	return &tarballGets
}

func signedAssets(sc signedChecksums) map[string][]byte {
	return map[string][]byte{
		"checksums.txt":                        sc.checksums,
		"checksums.txt" + release.BundleSuffix: sc.bundle,
		"cyfr-scaffold.tar.gz":                 sc.tarball,
	}
}

func extracted(t *testing.T) []string {
	t.Helper()
	entries, err := os.ReadDir(".")
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, e := range entries {
		names = append(names, e.Name())
	}
	return names
}

// A checksums.txt signed by the release workflow for the version lets the
// tarball it names extract as before.
func TestSignedChecksumsExtract(t *testing.T) {
	sc := readSignedChecksums(t)
	serveScaffold(t, sc, sc.version, signedAssets(sc))
	if err := Download(sc.version); err != nil {
		t.Fatalf("Download: %v", err)
	}
	if got := extracted(t); !slices.Equal(got, []string{"configuration-guide.md", "docker-compose.yml"}) {
		t.Errorf("extracted %v", got)
	}
}

// A checksums.txt that is not the release workflow's signed file for the
// version refuses with release.ErrUnverified before the tarball is
// downloaded, and nothing is extracted, even when the tarball served
// matches the line the forged checksums.txt names.
func TestUnverifiedChecksumsRefuse(t *testing.T) {
	sc := readSignedChecksums(t)

	evil := evilTarball(t)
	evilSum := sha256.Sum256(evil)
	goodSum := sha256.Sum256(sc.tarball)
	forged := bytes.Replace(sc.checksums, []byte(hex.EncodeToString(goodSum[:])), []byte(hex.EncodeToString(evilSum[:])), 1)
	if bytes.Equal(forged, sc.checksums) {
		t.Fatal("the signed checksums.txt does not name the tarball's digest")
	}

	cases := []struct {
		name    string
		version string
		edit    func(assets map[string][]byte)
	}{
		{"an unsigned checksums.txt naming another tarball", sc.version, func(a map[string][]byte) {
			a["checksums.txt"], a["cyfr-scaffold.tar.gz"] = forged, evil
			a["checksums.txt"+release.BundleSuffix] = []byte(`{}`)
		}},
		{"a bundle that is not a bundle", sc.version, func(a map[string][]byte) {
			a["checksums.txt"+release.BundleSuffix] = []byte("not a bundle")
		}},
		{"checksums.txt changed after signing", sc.version, func(a map[string][]byte) {
			a["checksums.txt"], a["cyfr-scaffold.tar.gz"] = forged, evil
		}},
		{"checksums.txt signed for another release", "1.2.4", func(map[string][]byte) {}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			assets := signedAssets(sc)
			c.edit(assets)
			tarballGets := serveScaffold(t, sc, c.version, assets)
			err := Download(c.version)
			if !errors.Is(err, release.ErrUnverified) {
				t.Errorf("Download = %v, want release.ErrUnverified", err)
			}
			if n := tarballGets.Load(); n != 0 {
				t.Errorf("the tarball was downloaded %d times", n)
			}
			if got := extracted(t); len(got) != 0 {
				t.Errorf("extracted %v", got)
			}
		})
	}

	// A checksums.txt whose bundle is missing is a transport failure: it
	// is not release.ErrUnverified, and nothing is extracted either.
	t.Run("no bundle", func(t *testing.T) {
		assets := signedAssets(sc)
		delete(assets, "checksums.txt"+release.BundleSuffix)
		tarballGets := serveScaffold(t, sc, sc.version, assets)
		err := Download(sc.version)
		if err == nil || errors.Is(err, release.ErrUnverified) || !strings.Contains(err.Error(), "404") {
			t.Errorf("Download = %v, want a 404 transport error", err)
		}
		if n := tarballGets.Load(); n != 0 {
			t.Errorf("the tarball was downloaded %d times", n)
		}
		if got := extracted(t); len(got) != 0 {
			t.Errorf("extracted %v", got)
		}
	})
}

func evilTarball(t *testing.T) []byte {
	t.Helper()
	var buf bytes.Buffer
	gz := gzip.NewWriter(&buf)
	tw := tar.NewWriter(gz)
	body := "services: {evil: {image: attacker/evil}}\n"
	if err := tw.WriteHeader(&tar.Header{Name: "docker-compose.yml", Mode: 0o644, Size: int64(len(body)), Typeflag: tar.TypeReg}); err != nil {
		t.Fatal(err)
	}
	if _, err := tw.Write([]byte(body)); err != nil {
		t.Fatal(err)
	}
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}
	if err := gz.Close(); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}
