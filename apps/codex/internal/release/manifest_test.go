// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package release

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/asn1"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"flag"
	"fmt"
	"math/big"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/digitorus/timestamp"
	ct "github.com/google/certificate-transparency-go"
	cttls "github.com/google/certificate-transparency-go/tls"
	ctx509util "github.com/google/certificate-transparency-go/x509util"
	protobundle "github.com/sigstore/protobuf-specs/gen/pb-go/bundle/v1"
	protocommon "github.com/sigstore/protobuf-specs/gen/pb-go/common/v1"
	protorekor "github.com/sigstore/protobuf-specs/gen/pb-go/rekor/v1"
	"github.com/sigstore/rekor/pkg/util"
	"github.com/sigstore/sigstore-go/pkg/root"
	"github.com/sigstore/sigstore/pkg/signature"
	"google.golang.org/protobuf/encoding/protojson"
)

var regenerate = flag.Bool("regenerate", false, "rewrite the signature section of tests/fixtures/release_manifest.json under a new test instance")

var fixturePath = filepath.Join("..", "..", "..", "..", "tests", "fixtures", "release_manifest.json")

// releaseFixture is tests/fixtures/release_manifest.json.
type releaseFixture struct {
	Comment   string            `json:"comment"`
	Valid     json.RawMessage   `json:"valid"`
	Refused   []refusedManifest `json:"refused"`
	Signature signatureVectors  `json:"signature"`
}

type refusedManifest struct {
	Name     string          `json:"name"`
	Manifest json.RawMessage `json:"manifest"`
}

type signatureVectors struct {
	Version     string          `json:"version"`
	TrustedRoot json.RawMessage `json:"trusted_root"`
	Valid       signedVector    `json:"valid"`
	Refused     []signedVector  `json:"refused"`
	Checksums   checksumsVector `json:"checksums"`
}

// signedVector is a manifest's exact bytes and a bundle over them (or over
// other bytes). RefusedBy names the step that refuses a refused vector:
// "signature" (VerifyBlob), "manifest" (ParseManifest after a signature
// that verifies) or "version" (VerifyManifest's version check after both).
type signedVector struct {
	Name      string          `json:"name,omitempty"`
	Version   string          `json:"version,omitempty"`
	RefusedBy string          `json:"refused_by,omitempty"`
	Manifest  string          `json:"manifest"`
	Bundle    json.RawMessage `json:"bundle"`
}

// checksumsVector is a release's checksums.txt signed as the release
// workflow signs it, with the scaffold tarball its line names, for the
// scaffold package's tests.
type checksumsVector struct {
	Version   string          `json:"version"`
	Checksums string          `json:"checksums"`
	Bundle    json.RawMessage `json:"bundle"`
	Tarball   []byte          `json:"tarball"`
}

func readFixture(t *testing.T) releaseFixture {
	t.Helper()
	raw, err := os.ReadFile(fixturePath)
	if err != nil {
		t.Fatalf("read the vector file: %v", err)
	}
	var f releaseFixture
	if err := json.Unmarshal(raw, &f); err != nil {
		t.Fatalf("parse the vector file: %v", err)
	}
	if len(f.Valid) == 0 || len(f.Refused) == 0 || f.Signature.Version == "" || len(f.Signature.TrustedRoot) == 0 ||
		f.Signature.Valid.Manifest == "" || len(f.Signature.Refused) == 0 || f.Signature.Checksums.Checksums == "" {
		t.Fatal("the vector file lacks what this test reads")
	}
	return f
}

func fixtureRoot(t *testing.T, f releaseFixture) root.TrustedMaterial {
	t.Helper()
	trusted, err := root.NewTrustedRootFromJSON(f.Signature.TrustedRoot)
	if err != nil {
		t.Fatalf("the vector file's trusted root: %v", err)
	}
	return trusted
}

func TestValidManifestParses(t *testing.T) {
	f := readFixture(t)
	m, err := ParseManifest(f.Valid)
	if err != nil {
		t.Fatalf("the valid manifest: %v", err)
	}
	if m.Version != "1.2.3" {
		t.Errorf("version = %q", m.Version)
	}
	for _, repo := range []string{RepoCyfr, RepoCyfrLocus, RepoCaddy} {
		if d, ok := m.Digest(repo); !ok || !digestPattern.MatchString(d) {
			t.Errorf("Digest(%s) = %q, %v", repo, d, ok)
		}
	}
	if _, ok := m.Digest("ghcr.io/cyfrworks/other"); ok {
		t.Error("Digest answers a repository the manifest does not name")
	}
	if !digestPattern.MatchString(m.Scaffold) {
		t.Errorf("scaffold = %q", m.Scaffold)
	}
}

func TestRefusedManifestsRefuse(t *testing.T) {
	f := readFixture(t)
	for _, v := range f.Refused {
		if _, err := ParseManifest(v.Manifest); !errors.Is(err, ErrUnverified) {
			t.Errorf("%s: ParseManifest(%s) = %v, want ErrUnverified", v.Name, v.Manifest, err)
		}
	}
}

// What a JSON value in the vector file cannot carry, since a reader that
// keeps the last of a repeated key or stops at the first value would see a
// valid manifest there.
func TestManifestTextOutsideOneObjectRefuses(t *testing.T) {
	f := readFixture(t)
	valid := strings.TrimSpace(string(f.Valid))
	cases := map[string]string{
		"empty":                "",
		"whitespace":           "  \n",
		"trailing data":        valid + " x",
		"a second object":      valid + valid,
		"a repeated key":       strings.Replace(valid, "{", `{"version": "1.2.4",`, 1),
		"a repeated image key": strings.Replace(valid, `"images": {`, `"images": {"caddy": "sha256:`+strings.Repeat("0", 64)+`",`, 1),
		"truncated":            valid[:len(valid)-1],
	}
	for name, text := range cases {
		if text == valid {
			t.Fatalf("%s: the case did not change the manifest", name)
		}
		if _, err := ParseManifest([]byte(text)); !errors.Is(err, ErrUnverified) {
			t.Errorf("%s: ParseManifest = %v, want ErrUnverified", name, err)
		}
	}
	if _, err := ParseManifest([]byte(valid + "\n")); err != nil {
		t.Errorf("a trailing newline: %v", err)
	}
}

func TestSignedManifestVerifies(t *testing.T) {
	f := readFixture(t)
	trusted := fixtureRoot(t, f)
	sig := f.Signature
	m, err := VerifyManifest([]byte(sig.Valid.Manifest), sig.Valid.Bundle, sig.Version, trusted)
	if err != nil {
		t.Fatalf("the signed manifest: %v", err)
	}
	want, err := ParseManifest(f.Valid)
	if err != nil {
		t.Fatal(err)
	}
	if *m != *want {
		t.Errorf("the signed manifest is %+v, the valid manifest %+v", *m, *want)
	}
}

func TestRefusedSignaturesRefuse(t *testing.T) {
	f := readFixture(t)
	trusted := fixtureRoot(t, f)
	for _, v := range f.Signature.Refused {
		data := []byte(v.Manifest)
		_, err := VerifyManifest(data, v.Bundle, v.Version, trusted)
		if !errors.Is(err, ErrUnverified) {
			t.Errorf("%s: VerifyManifest = %v, want ErrUnverified", v.Name, err)
			continue
		}
		t.Logf("%s: %v", v.Name, err)
		// Each vector is refused for the reason it names, so a case about
		// identity or version is genuinely signed and proves the verifier
		// rather than a parse error.
		blobErr := VerifyBlob(data, v.Bundle, v.Version, trusted)
		switch v.RefusedBy {
		case "signature":
			if blobErr == nil {
				t.Errorf("%s: the signature verifies", v.Name)
			}
		case "manifest":
			if blobErr != nil {
				t.Errorf("%s: the signature does not verify: %v", v.Name, blobErr)
			}
			if _, err := ParseManifest(data); err == nil {
				t.Errorf("%s: the manifest parses", v.Name)
			}
		case "version":
			if blobErr != nil {
				t.Errorf("%s: the signature does not verify: %v", v.Name, blobErr)
			}
			if m, err := ParseManifest(data); err != nil || m.Version == v.Version {
				t.Errorf("%s: the manifest is %+v, %v; want a valid manifest of another version", v.Name, m, err)
			}
		default:
			t.Errorf("%s: refused_by %q is not signature, manifest or version", v.Name, v.RefusedBy)
		}
	}
}

// Verification takes its trust from the argument alone: the valid vector
// fails under another instance's root, and neither VerifyBlob nor
// VerifyManifest consults TrustMaterial.
func TestVerificationTrustsOnlyItsArgument(t *testing.T) {
	f := readFixture(t)
	saved := TrustMaterial
	t.Cleanup(func() { TrustMaterial = saved })
	TrustMaterial = func(context.Context) (root.TrustedMaterial, error) {
		t.Error("verification consulted TrustMaterial")
		return nil, errors.New("not here")
	}

	other, err := newTestSigstore(time.Now(), 24*time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	otherRoot, err := other.trustedRoot()
	if err != nil {
		t.Fatal(err)
	}
	sig := f.Signature
	if _, err := VerifyManifest([]byte(sig.Valid.Manifest), sig.Valid.Bundle, sig.Version, otherRoot); !errors.Is(err, ErrUnverified) {
		t.Errorf("the valid vector under another instance's root: %v, want ErrUnverified", err)
	}
	if err := VerifyBlob([]byte(sig.Valid.Manifest), sig.Valid.Bundle, sig.Version, nil); !errors.Is(err, ErrUnverified) {
		t.Errorf("the valid vector under no root: %v, want ErrUnverified", err)
	}
	if _, err := VerifyManifest([]byte(sig.Valid.Manifest), sig.Valid.Bundle, sig.Version, fixtureRoot(t, f)); err != nil {
		t.Errorf("the valid vector under its own root: %v", err)
	}
}

// Verification checks the certificate against the signed observer
// timestamps, never the wall clock: an instance placed six years in the
// past, whose certificates all expired five years ago, still verifies
// today, as the vector file will in later years. Its CA lifetime is one
// day, so its RFC 3161 timestamp, whose chain sigstore-go checks at the
// wall clock, no longer counts, and the transparency log's signed
// integrated time carries the verification alone.
func TestVerificationUsesSignedTimeNotTheClock(t *testing.T) {
	at := time.Now().AddDate(-6, 0, 0)
	s, err := newTestSigstore(at, 24*time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	trusted, err := s.trustedRoot()
	if err != nil {
		t.Fatal(err)
	}
	data := []byte("signed long ago\n")
	bundleJSON, err := s.sign(Identity("1.2.3"), Issuer, data)
	if err != nil {
		t.Fatal(err)
	}
	if err := VerifyBlob(data, bundleJSON, "1.2.3", trusted); err != nil {
		t.Errorf("a signature six years old: %v", err)
	}
	if err := VerifyBlob(append(data, '!'), bundleJSON, "1.2.3", trusted); !errors.Is(err, ErrUnverified) {
		t.Errorf("other bytes under the old signature: %v, want ErrUnverified", err)
	}
}

// The verifier requires what the public-good instance gives `cosign
// sign-blob --bundle`: an SCT in the certificate, a transparency log entry,
// and an observer timestamp, which a Rekor v1 entry's signed entry
// timestamp or an RFC 3161 timestamp (all a Rekor v2 entry has) provides.
func TestVerifyBlobRequiresTheLogTheSCTAndATimestamp(t *testing.T) {
	s, err := newTestSigstore(time.Now(), 24*time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	trusted, err := s.trustedRoot()
	if err != nil {
		t.Fatal(err)
	}
	data := []byte("checksums\n")
	cases := []struct {
		name     string
		opts     signOptions
		verifies bool
	}{
		{"everything", signOptions{}, true},
		{"no RFC 3161 timestamp", signOptions{noTSA: true}, true},
		{"no signed entry timestamp", signOptions{noPromise: true}, true},
		{"no SCT", signOptions{noSCT: true}, false},
		{"no transparency log entry", signOptions{noTlogEntry: true}, false},
		{"no observer timestamp", signOptions{noPromise: true, noTSA: true}, false},
	}
	for _, c := range cases {
		bundleJSON, err := s.signWith(Identity("1.2.3"), Issuer, data, c.opts)
		if err != nil {
			t.Fatal(err)
		}
		err = VerifyBlob(data, bundleJSON, "1.2.3", trusted)
		switch {
		case c.verifies && err != nil:
			t.Errorf("%s: %v", c.name, err)
		case !c.verifies && !errors.Is(err, ErrUnverified):
			t.Errorf("%s: %v, want ErrUnverified", c.name, err)
		case err != nil:
			t.Logf("%s: %v", c.name, err)
		}
	}
}

func TestVerifyBlobRefusesAVersionThatIsNotARelease(t *testing.T) {
	f := readFixture(t)
	trusted := fixtureRoot(t, f)
	sig := f.Signature
	for _, version := range []string{"", "dev", "v" + sig.Version, sig.Version + "-rc.1", sig.Version + "\n", "1.2", "1.2.3.4"} {
		if err := VerifyBlob([]byte(sig.Valid.Manifest), sig.Valid.Bundle, version, trusted); !errors.Is(err, ErrUnverified) {
			t.Errorf("version %q: %v, want ErrUnverified", version, err)
		}
	}
}

// serveRelease serves files under /<version>/ and counts every request.
func serveRelease(t *testing.T, files map[string][]byte) (*httptest.Server, *atomic.Int64) {
	t.Helper()
	var requests atomic.Int64
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		body, ok := files[r.URL.Path]
		if !ok {
			http.NotFound(w, r)
			return
		}
		_, _ = w.Write(body)
	}))
	t.Cleanup(srv.Close)
	return srv, &requests
}

// useFixtureRelease points FetchManifest at srv and its trust at the
// vector file's root, restoring both when the test ends.
func useFixtureRelease(t *testing.T, srv *httptest.Server, trusted root.TrustedMaterial) {
	t.Helper()
	savedURL, savedTrust := manifestURLTemplate, TrustMaterial
	t.Cleanup(func() { manifestURLTemplate, TrustMaterial = savedURL, savedTrust })
	manifestURLTemplate = srv.URL + "/%s/release.json"
	TrustMaterial = func(context.Context) (root.TrustedMaterial, error) { return trusted, nil }
}

func TestFetchManifest(t *testing.T) {
	f := readFixture(t)
	trusted := fixtureRoot(t, f)
	sig := f.Signature
	path := "/" + sig.Version + "/release.json"
	valid := map[string][]byte{path: []byte(sig.Valid.Manifest), path + BundleSuffix: sig.Valid.Bundle}

	t.Run("the signed pair", func(t *testing.T) {
		srv, _ := serveRelease(t, valid)
		useFixtureRelease(t, srv, trusted)
		m, err := FetchManifest(context.Background(), sig.Version)
		if err != nil {
			t.Fatalf("FetchManifest: %v", err)
		}
		if m.Version != sig.Version {
			t.Errorf("version = %q", m.Version)
		}
	})

	for _, missing := range []string{path, path + BundleSuffix} {
		t.Run("missing "+missing, func(t *testing.T) {
			files := map[string][]byte{}
			for k, v := range valid {
				if k != missing {
					files[k] = v
				}
			}
			srv, _ := serveRelease(t, files)
			useFixtureRelease(t, srv, trusted)
			_, err := FetchManifest(context.Background(), sig.Version)
			if err == nil || !strings.Contains(err.Error(), srv.URL+missing) || !strings.Contains(err.Error(), "404") {
				t.Errorf("FetchManifest = %v, want a 404 naming %s", err, srv.URL+missing)
			}
			if errors.Is(err, ErrUnverified) {
				t.Errorf("a missing file is a transport error, not ErrUnverified: %v", err)
			}
		})
	}

	for _, big := range []string{path, path + BundleSuffix} {
		t.Run("oversized "+big, func(t *testing.T) {
			files := map[string][]byte{}
			for k, v := range valid {
				files[k] = v
			}
			files[big] = bytes.Repeat([]byte(" "), maxManifestSize+1)
			srv, _ := serveRelease(t, files)
			useFixtureRelease(t, srv, trusted)
			_, err := FetchManifest(context.Background(), sig.Version)
			if err == nil || !strings.Contains(err.Error(), "limit") || !strings.Contains(err.Error(), srv.URL+big) {
				t.Errorf("FetchManifest = %v, want the size limit refused for %s", err, srv.URL+big)
			}
		})
	}

	t.Run("a tampered manifest", func(t *testing.T) {
		files := map[string][]byte{}
		for k, v := range valid {
			files[k] = v
		}
		files[path] = append([]byte(nil), files[path]...)
		files[path][bytes.IndexByte(files[path], '"')] = ' '
		srv, _ := serveRelease(t, files)
		useFixtureRelease(t, srv, trusted)
		if _, err := FetchManifest(context.Background(), sig.Version); !errors.Is(err, ErrUnverified) {
			t.Errorf("FetchManifest = %v, want ErrUnverified", err)
		}
	})

	t.Run("an unavailable trust root", func(t *testing.T) {
		srv, _ := serveRelease(t, valid)
		useFixtureRelease(t, srv, trusted)
		TrustMaterial = func(context.Context) (root.TrustedMaterial, error) { return nil, errors.New("no TUF") }
		if _, err := FetchManifest(context.Background(), sig.Version); err == nil || !strings.Contains(err.Error(), "no TUF") {
			t.Errorf("FetchManifest = %v, want the trust root's error", err)
		}
	})

	for _, version := range []string{"dev", "", "v1.2.3"} {
		t.Run("version "+version, func(t *testing.T) {
			srv, requests := serveRelease(t, valid)
			useFixtureRelease(t, srv, trusted)
			if _, err := FetchManifest(context.Background(), version); err == nil || !strings.Contains(err.Error(), "not a release build") {
				t.Errorf("FetchManifest(%q) = %v, want a refusal naming the build", version, err)
			}
			if n := requests.Load(); n != 0 {
				t.Errorf("FetchManifest(%q) made %d requests before refusing", version, n)
			}
		})
	}
}

// TestRegenerateFixture rewrites the vector file's signature section under
// a new test instance, keeping its comment, valid and refused sections:
//
//	go test ./internal/release -run TestRegenerateFixture -regenerate
func TestRegenerateFixture(t *testing.T) {
	if !*regenerate {
		t.Skip("run with -regenerate to rewrite the vector file's signature section")
	}
	raw, err := os.ReadFile(fixturePath)
	if err != nil {
		t.Fatal(err)
	}
	var f releaseFixture
	if err := json.Unmarshal(raw, &f); err != nil {
		t.Fatal(err)
	}
	sig, err := generateSignatureVectors(f.Valid, time.Now().UTC().Truncate(time.Second))
	if err != nil {
		t.Fatal(err)
	}
	f.Signature = *sig
	out, err := json.MarshalIndent(f, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(fixturePath, append(out, '\n'), 0o644); err != nil {
		t.Fatal(err)
	}
}

// generateSignatureVectors signs the valid manifest and each refused case
// under a new test instance at the instant at. Its certificate authorities
// stay valid for fifty years, so even the RFC 3161 timestamp, whose chain
// sigstore-go checks at the wall clock, keeps verifying.
func generateSignatureVectors(valid json.RawMessage, at time.Time) (*signatureVectors, error) {
	const version = "1.2.3"
	s, err := newTestSigstore(at, 50*365*24*time.Hour)
	if err != nil {
		return nil, err
	}
	trusted, err := s.trustedRoot()
	if err != nil {
		return nil, err
	}
	rootJSON, err := trusted.MarshalJSON()
	if err != nil {
		return nil, err
	}

	var manifest map[string]any
	if err := json.Unmarshal(valid, &manifest); err != nil {
		return nil, err
	}
	render := func(m map[string]any) ([]byte, error) {
		out, err := json.MarshalIndent(m, "", "  ")
		return append(out, '\n'), err
	}
	with := func(edit func(m map[string]any)) ([]byte, error) {
		var m map[string]any
		if err := json.Unmarshal(valid, &m); err != nil {
			return nil, err
		}
		edit(m)
		return render(m)
	}
	validBytes, err := render(manifest)
	if err != nil {
		return nil, err
	}
	validBundle, err := s.sign(Identity(version), Issuer, validBytes)
	if err != nil {
		return nil, err
	}

	other, err := newTestSigstore(at, 50*365*24*time.Hour)
	if err != nil {
		return nil, err
	}

	out := &signatureVectors{
		Version:     version,
		TrustedRoot: rootJSON,
		Valid:       signedVector{Manifest: string(validBytes), Bundle: validBundle},
	}
	add := func(name, refusedBy string, data []byte, bundleJSON []byte) {
		out.Refused = append(out.Refused, signedVector{Name: name, Version: version, RefusedBy: refusedBy, Manifest: string(data), Bundle: bundleJSON})
	}
	signed := func(signer *testSigstore, identity, issuer string, data []byte) []byte {
		if err == nil {
			var b []byte
			b, err = signer.sign(identity, issuer, data)
			return b
		}
		return nil
	}

	add("signed by the release workflow at another tag", "signature", validBytes,
		signed(s, Identity("1.2.4"), Issuer, validBytes))
	add("signed by the release workflow of another repository", "signature", validBytes,
		signed(s, "https://github.com/cyfrworks-fork/cyfr/.github/workflows/release.yml@refs/tags/"+version, Issuer, validBytes))
	add("signed by another workflow of the repository", "signature", validBytes,
		signed(s, "https://github.com/cyfrworks/cyfr/.github/workflows/ci.yml@refs/tags/"+version, Issuer, validBytes))
	add("signed by the release workflow on a branch", "signature", validBytes,
		signed(s, "https://github.com/cyfrworks/cyfr/.github/workflows/release.yml@refs/heads/main", Issuer, validBytes))
	add("signed under the release identity by another issuer", "signature", validBytes,
		signed(s, Identity(version), "https://accounts.google.com", validBytes))
	add("signed by another Sigstore instance", "signature", validBytes,
		signed(other, Identity(version), Issuer, validBytes))

	nextRelease, err2 := with(func(m map[string]any) { m["version"] = "1.2.4" })
	if err2 != nil {
		return nil, err2
	}
	add("another release's manifest, signed for its own tag", "signature", nextRelease,
		signed(s, Identity("1.2.4"), Issuer, nextRelease))
	add("a manifest naming another version, signed for this tag", "version", nextRelease,
		signed(s, Identity(version), Issuer, nextRelease))

	tampered, err2 := with(func(m map[string]any) {
		images := m["images"].(map[string]any)
		images["cyfr"] = "sha256:" + strings.Repeat("e", 64)
	})
	if err2 != nil {
		return nil, err2
	}
	add("one digest changed after signing", "signature", tampered, validBundle)

	noCaddy, err2 := with(func(m map[string]any) { delete(m["images"].(map[string]any), "caddy") })
	if err2 != nil {
		return nil, err2
	}
	add("the caddy digest dropped after signing", "signature", noCaddy, validBundle)
	add("a signed manifest without the caddy digest", "manifest", noCaddy,
		signed(s, Identity(version), Issuer, noCaddy))

	add("the bundle of another file", "signature", validBytes,
		signed(s, Identity(version), Issuer, []byte("cyfr_1.2.3_linux_amd64.tar.gz\n")))
	add("an empty bundle", "signature", validBytes, []byte(`{}`))
	add("a bundle that is not a bundle", "signature", validBytes, []byte(`"not a sigstore bundle"`))

	if err != nil {
		return nil, err
	}

	checksums, err := generateChecksumsVector(s, version)
	if err != nil {
		return nil, err
	}
	out.Checksums = *checksums
	return out, nil
}

// generateChecksumsVector builds a small scaffold tarball and a
// checksums.txt naming it beside a release binary, signed as the release
// workflow signs checksums.txt.
func generateChecksumsVector(s *testSigstore, version string) (*checksumsVector, error) {
	var buf bytes.Buffer
	gz := gzip.NewWriter(&buf)
	tw := tar.NewWriter(gz)
	files := []struct{ name, body string }{
		{"configuration-guide.md", "# Configuration\n"},
		{"docker-compose.yml", "services: {}\n"},
	}
	for _, file := range files {
		if err := tw.WriteHeader(&tar.Header{Name: file.name, Mode: 0o644, Size: int64(len(file.body)), Typeflag: tar.TypeReg, ModTime: s.at}); err != nil {
			return nil, err
		}
		if _, err := tw.Write([]byte(file.body)); err != nil {
			return nil, err
		}
	}
	if err := tw.Close(); err != nil {
		return nil, err
	}
	if err := gz.Close(); err != nil {
		return nil, err
	}
	tarball := buf.Bytes()
	sum := sha256.Sum256(tarball)
	binary := sha256.Sum256([]byte("cyfr " + version))
	checksums := fmt.Sprintf("%x  cyfr-scaffold.tar.gz\n%x  cyfr_%s_linux_amd64.tar.gz\n", sum, binary, version)
	bundleJSON, err := s.sign(Identity(version), Issuer, []byte(checksums))
	if err != nil {
		return nil, err
	}
	return &checksumsVector{Version: version, Checksums: checksums, Bundle: bundleJSON, Tarball: tarball}, nil
}

// testSigstore is a Sigstore instance of its own — a Fulcio CA, a Rekor
// log, a CT log and a timestamp authority — placed at the instant at. It
// issues what the public-good instance issues for `cosign sign-blob
// --bundle`: a certificate whose URI SAN is the workflow identity, with
// both Fulcio issuer extensions and an embedded SCT, a hashedrekord entry
// with an inclusion promise and an inclusion proof, and an RFC 3161
// timestamp, in a v0.3 bundle. sigstore-go's own pkg/testing/ca cannot
// serve here: its certificates carry an e-mail SAN and no SCT, and its
// instant is always the wall clock.
type testSigstore struct {
	at         time.Time
	rootCert   *x509.Certificate
	fulcioCert *x509.Certificate
	fulcioKey  *ecdsa.PrivateKey
	tsaInter   *x509.Certificate
	tsaLeaf    *x509.Certificate
	tsaKey     *ecdsa.PrivateKey
	rekorKey   *ecdsa.PrivateKey
	ctKey      *ecdsa.PrivateKey
}

const (
	testFulcioURI = "https://fulcio.test.invalid"
	testTSAURI    = "https://timestamp.test.invalid"
	testRekorURL  = "https://rekor.test.invalid"
	testCTURL     = "https://ctfe.test.invalid"
)

var (
	oidIssuerV1  = asn1.ObjectIdentifier{1, 3, 6, 1, 4, 1, 57264, 1, 1}
	oidIssuerV2  = asn1.ObjectIdentifier{1, 3, 6, 1, 4, 1, 57264, 1, 8}
	oidSCTList   = asn1.ObjectIdentifier{1, 3, 6, 1, 4, 1, 11129, 2, 4, 2}
	oidExtKeyUse = asn1.ObjectIdentifier{2, 5, 29, 37}
	oidTimestamp = asn1.ObjectIdentifier{1, 3, 6, 1, 5, 5, 7, 3, 8}
)

func newKey() (*ecdsa.PrivateKey, error) { return ecdsa.GenerateKey(elliptic.P256(), rand.Reader) }

func serial() (*big.Int, error) { return rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 120)) }

func issue(tmpl, parent *x509.Certificate, pub any, signer crypto.Signer) (*x509.Certificate, error) {
	der, err := x509.CreateCertificate(rand.Reader, tmpl, parent, pub, signer)
	if err != nil {
		return nil, err
	}
	return x509.ParseCertificate(der)
}

// newTestSigstore makes an instance whose certificate authorities are valid
// from an hour before at for lifetime.
func newTestSigstore(at time.Time, lifetime time.Duration) (*testSigstore, error) {
	s := &testSigstore{at: at}
	var err error
	ca := func(cn string, eku x509.ExtKeyUsage, parent *x509.Certificate, parentKey crypto.Signer) (*x509.Certificate, *ecdsa.PrivateKey, error) {
		key, err := newKey()
		if err != nil {
			return nil, nil, err
		}
		sn, err := serial()
		if err != nil {
			return nil, nil, err
		}
		tmpl := &x509.Certificate{
			SerialNumber:          sn,
			Subject:               pkix.Name{CommonName: cn, Organization: []string{"test.invalid"}},
			NotBefore:             at.Add(-time.Hour),
			NotAfter:              at.Add(lifetime),
			KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
			BasicConstraintsValid: true,
			IsCA:                  true,
		}
		if eku != 0 {
			tmpl.ExtKeyUsage = []x509.ExtKeyUsage{eku}
		}
		if parent == nil {
			parent, parentKey = tmpl, key
		}
		cert, err := issue(tmpl, parent, &key.PublicKey, parentKey)
		return cert, key, err
	}
	rootCert, rootKey, err := ca("test sigstore root", 0, nil, nil)
	if err != nil {
		return nil, err
	}
	s.rootCert = rootCert
	if s.fulcioCert, s.fulcioKey, err = ca("test fulcio intermediate", x509.ExtKeyUsageCodeSigning, rootCert, rootKey); err != nil {
		return nil, err
	}
	tsaInter, tsaInterKey, err := ca("test tsa intermediate", x509.ExtKeyUsageTimeStamping, rootCert, rootKey)
	if err != nil {
		return nil, err
	}
	s.tsaInter = tsaInter

	if s.tsaKey, err = newKey(); err != nil {
		return nil, err
	}
	eku, err := asn1.Marshal([]asn1.ObjectIdentifier{oidTimestamp})
	if err != nil {
		return nil, err
	}
	sn, err := serial()
	if err != nil {
		return nil, err
	}
	if s.tsaLeaf, err = issue(&x509.Certificate{
		SerialNumber:    sn,
		Subject:         pkix.Name{CommonName: "test tsa"},
		NotBefore:       at.Add(-time.Hour),
		NotAfter:        at.Add(lifetime),
		KeyUsage:        x509.KeyUsageDigitalSignature,
		ExtraExtensions: []pkix.Extension{{Id: oidExtKeyUse, Critical: true, Value: eku}},
	}, tsaInter, &s.tsaKey.PublicKey, tsaInterKey); err != nil {
		return nil, err
	}

	if s.rekorKey, err = newKey(); err != nil {
		return nil, err
	}
	if s.ctKey, err = newKey(); err != nil {
		return nil, err
	}
	return s, nil
}

func logID(pub crypto.PublicKey) ([]byte, error) {
	der, err := x509.MarshalPKIXPublicKey(pub)
	if err != nil {
		return nil, err
	}
	sum := sha256.Sum256(der)
	return sum[:], nil
}

// trustedRoot is the instance's trusted_root.json, read back as a
// verifier reads it.
func (s *testSigstore) trustedRoot() (*root.TrustedRoot, error) {
	start := s.at.Add(-time.Hour)
	rekorID, err := logID(&s.rekorKey.PublicKey)
	if err != nil {
		return nil, err
	}
	ctID, err := logID(&s.ctKey.PublicKey)
	if err != nil {
		return nil, err
	}
	tr, err := root.NewTrustedRoot(root.TrustedRootMediaType01,
		[]root.CertificateAuthority{&root.FulcioCertificateAuthority{
			Root: s.rootCert, Intermediates: []*x509.Certificate{s.fulcioCert}, ValidityPeriodStart: start, URI: testFulcioURI,
		}},
		map[string]*root.TransparencyLog{hex.EncodeToString(ctID): {
			BaseURL: testCTURL, ID: ctID, ValidityPeriodStart: start, HashFunc: crypto.SHA256, PublicKey: &s.ctKey.PublicKey, SignatureHashFunc: crypto.SHA256,
		}},
		[]root.TimestampingAuthority{&root.SigstoreTimestampingAuthority{
			Root: s.rootCert, Intermediates: []*x509.Certificate{s.tsaInter}, Leaf: s.tsaLeaf, ValidityPeriodStart: start, URI: testTSAURI,
		}},
		map[string]*root.TransparencyLog{hex.EncodeToString(rekorID): {
			BaseURL: testRekorURL, ID: rekorID, ValidityPeriodStart: start, HashFunc: crypto.SHA256, PublicKey: &s.rekorKey.PublicKey, SignatureHashFunc: crypto.SHA256,
		}},
	)
	if err != nil {
		return nil, err
	}
	rootJSON, err := tr.MarshalJSON()
	if err != nil {
		return nil, err
	}
	return root.NewTrustedRootFromJSON(rootJSON)
}

// leafCert issues the signing certificate for identity and issuer, valid
// for ten minutes from a minute before the instant, with an SCT from the
// instance's CT log embedded over its precertificate.
func (s *testSigstore) leafCert(identity, issuer string, pub *ecdsa.PublicKey, withSCT bool) (*x509.Certificate, error) {
	san, err := url.Parse(identity)
	if err != nil {
		return nil, err
	}
	issuerV2, err := asn1.MarshalWithParams(issuer, "utf8")
	if err != nil {
		return nil, err
	}
	sn, err := serial()
	if err != nil {
		return nil, err
	}
	tmpl := &x509.Certificate{
		SerialNumber: sn,
		NotBefore:    s.at.Add(-time.Minute),
		NotAfter:     s.at.Add(9 * time.Minute),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageCodeSigning},
		URIs:         []*url.URL{san},
		ExtraExtensions: []pkix.Extension{
			{Id: oidIssuerV1, Value: []byte(issuer)},
			{Id: oidIssuerV2, Value: issuerV2},
		},
	}
	// The precertificate is the certificate without its SCT list; the
	// list goes last, so removing it gives back exactly the TBS the log
	// signed.
	pre, err := issue(tmpl, s.fulcioCert, pub, s.fulcioKey)
	if err != nil || !withSCT {
		return pre, err
	}
	ctID, err := logID(&s.ctKey.PublicKey)
	if err != nil {
		return nil, err
	}
	sct := ct.SignedCertificateTimestamp{SCTVersion: ct.V1, Timestamp: uint64(s.at.UnixMilli())}
	copy(sct.LogID.KeyID[:], ctID)
	input, err := ct.SerializeSCTSignatureInput(sct, ct.LogEntry{Leaf: ct.MerkleTreeLeaf{
		Version:  ct.V1,
		LeafType: ct.TimestampedEntryLeafType,
		TimestampedEntry: &ct.TimestampedEntry{
			Timestamp: sct.Timestamp,
			EntryType: ct.PrecertLogEntryType,
			PrecertEntry: &ct.PreCert{
				IssuerKeyHash:  sha256.Sum256(s.fulcioCert.RawSubjectPublicKeyInfo),
				TBSCertificate: pre.RawTBSCertificate,
			},
		},
	}})
	if err != nil {
		return nil, err
	}
	digest := sha256.Sum256(input)
	sctSig, err := ecdsa.SignASN1(rand.Reader, s.ctKey, digest[:])
	if err != nil {
		return nil, err
	}
	sct.Signature = ct.DigitallySigned{
		Algorithm: cttls.SignatureAndHashAlgorithm{Hash: cttls.SHA256, Signature: cttls.ECDSA},
		Signature: sctSig,
	}
	list, err := ctx509util.MarshalSCTsIntoSCTList([]*ct.SignedCertificateTimestamp{&sct})
	if err != nil {
		return nil, err
	}
	listBytes, err := cttls.Marshal(*list)
	if err != nil {
		return nil, err
	}
	ext, err := asn1.Marshal(listBytes)
	if err != nil {
		return nil, err
	}
	tmpl.ExtraExtensions = append(tmpl.ExtraExtensions, pkix.Extension{Id: oidSCTList, Value: ext})
	return issue(tmpl, s.fulcioCert, pub, s.fulcioKey)
}

// sign answers a v0.3 bundle of a message signature over artifact by a
// fresh key certified for identity and issuer, logged and timestamped at
// the instance's instant.
func (s *testSigstore) sign(identity, issuer string, artifact []byte) ([]byte, error) {
	return s.signWith(identity, issuer, artifact, signOptions{})
}

// signOptions leaves out parts of what sign issues.
type signOptions struct {
	noSCT       bool // the certificate carries no SCT
	noTlogEntry bool // the bundle carries no transparency log entry
	noPromise   bool // the log entry carries no signed entry timestamp
	noTSA       bool // the bundle carries no RFC 3161 timestamp
}

func (s *testSigstore) signWith(identity, issuer string, artifact []byte, opts signOptions) ([]byte, error) {
	key, err := newKey()
	if err != nil {
		return nil, err
	}
	leaf, err := s.leafCert(identity, issuer, &key.PublicKey, !opts.noSCT)
	if err != nil {
		return nil, err
	}
	digest := sha256.Sum256(artifact)
	sig, err := ecdsa.SignASN1(rand.Reader, key, digest[:])
	if err != nil {
		return nil, err
	}

	// The Rekor hashedrekord entry, its signed entry timestamp and an
	// inclusion proof in a one-entry tree under a signed checkpoint.
	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: leaf.Raw})
	body, err := json.Marshal(map[string]any{
		"apiVersion": "0.0.1",
		"kind":       "hashedrekord",
		"spec": map[string]any{
			"data": map[string]any{"hash": map[string]any{"algorithm": "sha256", "value": hex.EncodeToString(digest[:])}},
			"signature": map[string]any{
				"content":   base64.StdEncoding.EncodeToString(sig),
				"publicKey": map[string]any{"content": base64.StdEncoding.EncodeToString(certPEM)},
			},
		},
	})
	if err != nil {
		return nil, err
	}
	rekorID, err := logID(&s.rekorKey.PublicKey)
	if err != nil {
		return nil, err
	}
	const logIndex = 0
	integrated := s.at.Unix()
	// The payload's keys marshal sorted and its numbers as integers, which
	// is its RFC 8785 canonical form.
	payload, err := json.Marshal(map[string]any{
		"body":           base64.StdEncoding.EncodeToString(body),
		"integratedTime": integrated,
		"logIndex":       logIndex,
		"logID":          hex.EncodeToString(rekorID),
	})
	if err != nil {
		return nil, err
	}
	payloadDigest := sha256.Sum256(payload)
	set, err := ecdsa.SignASN1(rand.Reader, s.rekorKey, payloadDigest[:])
	if err != nil {
		return nil, err
	}
	leafHash := sha256.Sum256(append([]byte{0}, body...))
	rekorSigner, err := signature.LoadECDSASignerVerifier(s.rekorKey, crypto.SHA256)
	if err != nil {
		return nil, err
	}
	checkpoint, err := util.CreateAndSignCheckpoint(context.Background(), "rekor.test.invalid", 1, 1, leafHash[:], rekorSigner)
	if err != nil {
		return nil, err
	}

	tsr, err := (&timestamp.Timestamp{
		HashAlgorithm: crypto.SHA256,
		HashedMessage: func() []byte { h := sha256.Sum256(sig); return h[:] }(),
		Time:          s.at,
		Policy:        asn1.ObjectIdentifier{1, 3, 6, 1, 4, 1, 57264, 2},
	}).CreateResponseWithOpts(s.tsaLeaf, s.tsaKey, crypto.SHA256)
	if err != nil {
		return nil, err
	}

	b := &protobundle.Bundle{
		MediaType: "application/vnd.dev.sigstore.bundle.v0.3+json",
		VerificationMaterial: &protobundle.VerificationMaterial{
			Content: &protobundle.VerificationMaterial_Certificate{Certificate: &protocommon.X509Certificate{RawBytes: leaf.Raw}},
			TlogEntries: []*protorekor.TransparencyLogEntry{{
				LogIndex:          logIndex,
				LogId:             &protocommon.LogId{KeyId: rekorID},
				KindVersion:       &protorekor.KindVersion{Kind: "hashedrekord", Version: "0.0.1"},
				IntegratedTime:    integrated,
				InclusionPromise:  &protorekor.InclusionPromise{SignedEntryTimestamp: set},
				CanonicalizedBody: body,
				InclusionProof: &protorekor.InclusionProof{
					LogIndex:   logIndex,
					RootHash:   leafHash[:],
					TreeSize:   1,
					Hashes:     [][]byte{},
					Checkpoint: &protorekor.Checkpoint{Envelope: string(checkpoint)},
				},
			}},
			TimestampVerificationData: &protobundle.TimestampVerificationData{
				Rfc3161Timestamps: []*protocommon.RFC3161SignedTimestamp{{SignedTimestamp: tsr}},
			},
		},
		Content: &protobundle.Bundle_MessageSignature{MessageSignature: &protocommon.MessageSignature{
			MessageDigest: &protocommon.HashOutput{Algorithm: protocommon.HashAlgorithm_SHA2_256, Digest: digest[:]},
			Signature:     sig,
		}},
	}
	if opts.noTlogEntry {
		b.VerificationMaterial.TlogEntries = nil
	} else if opts.noPromise {
		b.VerificationMaterial.TlogEntries[0].InclusionPromise = nil
	}
	if opts.noTSA {
		b.VerificationMaterial.TimestampVerificationData = nil
	}
	return protojson.Marshal(b)
}
