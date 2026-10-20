// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package release

import (
	"archive/tar"
	"archive/zip"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/sigstore/sigstore-go/pkg/root"
)

func tarGz(t *testing.T, name string, body []byte) []byte {
	t.Helper()
	var buf bytes.Buffer
	gz := gzip.NewWriter(&buf)
	tw := tar.NewWriter(gz)
	for _, f := range []struct {
		name string
		body []byte
	}{{"README.md", []byte("# cyfr\n")}, {name, body}} {
		if err := tw.WriteHeader(&tar.Header{Name: f.name, Mode: 0o755, Size: int64(len(f.body)), Typeflag: tar.TypeReg}); err != nil {
			t.Fatal(err)
		}
		if _, err := tw.Write(f.body); err != nil {
			t.Fatal(err)
		}
	}
	if err := errors.Join(tw.Close(), gz.Close()); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func zipped(t *testing.T, name string, body []byte) []byte {
	t.Helper()
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	w, err := zw.Create(name)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := w.Write(body); err != nil {
		t.Fatal(err)
	}
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

// binaryRelease is one release's assets, signed by a test instance of its
// own as the release workflow signs them, served under /<version>/.
type binaryRelease struct {
	version string
	sig     *testSigstore
	trusted root.TrustedMaterial
	assets  map[string][]byte
}

func newBinaryRelease(t *testing.T, version string) *binaryRelease {
	t.Helper()
	sig, err := newTestSigstore(time.Now(), 24*time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	trusted, err := sig.trustedRoot()
	if err != nil {
		t.Fatal(err)
	}
	r := &binaryRelease{version: version, sig: sig, trusted: trusted, assets: map[string][]byte{}}
	r.assets[ArchiveName(version, "linux", "amd64")] = tarGz(t, "cyfr", []byte("cyfr linux "+version))
	r.assets[ArchiveName(version, "windows", "arm64")] = zipped(t, "cyfr.exe", []byte("cyfr windows "+version))
	r.assets[ArchiveName(version, "darwin", "arm64")] = tarGz(t, "other", []byte("no cyfr here"))
	r.signChecksums(t, Identity(version), Issuer)
	return r
}

// signChecksums writes checksums.txt over every archive and signs it under
// identity and issuer.
func (r *binaryRelease) signChecksums(t *testing.T, identity, issuer string) {
	t.Helper()
	var lines []string
	for name, data := range r.assets {
		if strings.HasPrefix(name, "cyfr_") {
			lines = append(lines, fmt.Sprintf("%x  %s", sha256.Sum256(data), name))
		}
	}
	checksums := []byte(strings.Join(lines, "\n") + "\n")
	bundle, err := r.sig.sign(identity, issuer, checksums)
	if err != nil {
		t.Fatal(err)
	}
	r.assets["checksums.txt"], r.assets["checksums.txt"+BundleSuffix] = checksums, bundle
}

// serve points FetchBinary at the release and its trust at the release's
// instance, restoring both when the test ends.
func (r *binaryRelease) serve(t *testing.T) {
	t.Helper()
	files := map[string][]byte{}
	for name, data := range r.assets {
		files["/"+r.version+"/"+name] = data
	}
	srv, _ := serveRelease(t, files)
	savedChecksums, savedBinary, savedTrust := checksumsURLTemplate, binaryURLTemplate, TrustMaterial
	t.Cleanup(func() {
		checksumsURLTemplate, binaryURLTemplate, TrustMaterial = savedChecksums, savedBinary, savedTrust
	})
	checksumsURLTemplate = srv.URL + "/%s/checksums.txt"
	binaryURLTemplate = srv.URL + "/%s/%s"
	TrustMaterial = func(context.Context) (root.TrustedMaterial, error) { return r.trusted, nil }
}

// The archive a signed checksums.txt names answers its binary, a gzipped
// tar's cyfr and a zip's cyfr.exe, for a release and a pre-release alike.
func TestFetchBinaryAnswersTheVerifiedBinary(t *testing.T) {
	for _, version := range []string{"0.9.0", "0.9.0-rc.1"} {
		r := newBinaryRelease(t, version)
		r.serve(t)
		for _, platform := range []struct{ goos, goarch, want string }{
			{"linux", "amd64", "cyfr linux " + version},
			{"windows", "arm64", "cyfr windows " + version},
		} {
			got, err := FetchBinary(context.Background(), version, platform.goos, platform.goarch)
			if err != nil {
				t.Fatalf("FetchBinary %s %s/%s: %v", version, platform.goos, platform.goarch, err)
			}
			if string(got) != platform.want {
				t.Errorf("FetchBinary %s %s/%s answered %q", version, platform.goos, platform.goarch, got)
			}
		}
	}
}

// Every way the archive is not the release workflow's for the version
// refuses with ErrUnverified, and answers no binary.
func TestFetchBinaryRefusesWhatDoesNotVerify(t *testing.T) {
	linux := ArchiveName("0.9.0", "linux", "amd64")
	cases := []struct {
		name    string
		version string
		goos    string
		edit    func(t *testing.T, r *binaryRelease)
	}{
		{"an archive changed after signing", "0.9.0", "linux", func(t *testing.T, r *binaryRelease) {
			r.assets[linux] = tarGz(t, "cyfr", []byte("attacker"))
		}},
		{"checksums.txt changed after signing", "0.9.0", "linux", func(t *testing.T, r *binaryRelease) {
			r.assets[linux] = tarGz(t, "cyfr", []byte("attacker"))
			sum := sha256.Sum256(r.assets[linux])
			lines := strings.Split(string(r.assets["checksums.txt"]), "\n")
			for i, line := range lines {
				if strings.HasSuffix(line, linux) {
					lines[i] = fmt.Sprintf("%x  %s", sum, linux)
				}
			}
			r.assets["checksums.txt"] = []byte(strings.Join(lines, "\n"))
		}},
		{"another workflow of the repository", "0.9.0", "linux", func(t *testing.T, r *binaryRelease) {
			r.signChecksums(t, "https://github.com/cyfrworks/cyfr/.github/workflows/test.yml@refs/tags/0.9.0", Issuer)
		}},
		{"the release workflow at another ref", "0.9.0", "linux", func(t *testing.T, r *binaryRelease) {
			r.signChecksums(t, "https://github.com/cyfrworks/cyfr/.github/workflows/release.yml@refs/heads/main", Issuer)
		}},
		{"another issuer", "0.9.0", "linux", func(t *testing.T, r *binaryRelease) {
			r.signChecksums(t, Identity("0.9.0"), "https://issuer.example")
		}},
		{"a bundle that is not a bundle", "0.9.0", "linux", func(t *testing.T, r *binaryRelease) {
			r.assets["checksums.txt"+BundleSuffix] = []byte("not a bundle")
		}},
		{"no line for the platform's archive", "0.9.0", "freebsd", func(*testing.T, *binaryRelease) {}},
		{"an archive without the binary", "0.9.0", "darwin", func(*testing.T, *binaryRelease) {}},
		{"a version that is not a release", "0.9", "linux", func(*testing.T, *binaryRelease) {}},
		{"a version with build metadata", "0.9.0+build.1", "linux", func(*testing.T, *binaryRelease) {}},
		// The pre-release's assets, their checksums.txt signed for the
		// release's tag.
		{"a pre-release signed for its release's tag", "0.9.0-rc.1", "linux", func(t *testing.T, r *binaryRelease) {
			r.signChecksums(t, Identity("0.9.0"), Issuer)
		}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			version := "0.9.0"
			if IsPrerelease(c.version) {
				version = c.version
			}
			r := newBinaryRelease(t, version)
			c.edit(t, r)
			r.serve(t)
			goarch := map[string]string{"linux": "amd64", "freebsd": "amd64", "darwin": "arm64"}[c.goos]
			got, err := FetchBinary(context.Background(), c.version, c.goos, goarch)
			if !errors.Is(err, ErrUnverified) {
				t.Errorf("FetchBinary = %v, want ErrUnverified", err)
			}
			if got != nil {
				t.Errorf("FetchBinary answered %d bytes", len(got))
			}
		})
	}

	// A missing signature is a transport failure, not a pass.
	r := newBinaryRelease(t, "0.9.0")
	delete(r.assets, "checksums.txt"+BundleSuffix)
	r.serve(t)
	if got, err := FetchBinary(context.Background(), "0.9.0", "linux", "amd64"); err == nil || got != nil || !strings.Contains(err.Error(), "404") {
		t.Errorf("FetchBinary without a bundle = %d bytes, %v; want a 404 refusal", len(got), err)
	}
}
