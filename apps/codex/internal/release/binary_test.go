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
	"os"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/sigstore/sigstore-go/pkg/root"
	"gopkg.in/yaml.v3"
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
	for _, p := range installers {
		r.assets[PackageName(version, p[0], p[1])] = []byte("the app's installer " + p[0] + " " + p[1] + " " + version)
	}
	r.signChecksums(t, Identity(version), Issuer)
	return r
}

// signChecksums writes checksums.txt over every archive and package and signs it under
// identity and issuer.
func (r *binaryRelease) signChecksums(t *testing.T, identity, issuer string) {
	t.Helper()
	var lines []string
	for name, data := range r.assets {
		if strings.HasPrefix(name, "cyfr_") || strings.HasPrefix(name, "cyfr-desktop_") {
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
	savedChecksums, savedDownload, savedTrust := checksumsURLTemplate, downloadURLTemplate, TrustMaterial
	t.Cleanup(func() {
		checksumsURLTemplate, downloadURLTemplate, TrustMaterial = savedChecksums, savedDownload, savedTrust
	})
	checksumsURLTemplate = srv.URL + "/%s/checksums.txt"
	downloadURLTemplate = srv.URL + "/%s/%s"
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

// signedPackage is the installer as cyfr screen on and cyfr update read
// it: the sum the signed checksums.txt names first (PackageChecksum), then
// the installer that has it (FetchPackage).
func signedPackage(version, goos, goarch string) ([]byte, error) {
	sum, err := PackageChecksum(context.Background(), version, goos, goarch)
	if err != nil {
		return nil, err
	}
	return FetchPackage(context.Background(), version, goos, goarch, sum)
}

// The CYFR app's five installers a release carries: Linux's and Windows'
// for amd64 and arm64, the Mac's for Apple silicon alone.
var installers = [][2]string{{"linux", "amd64"}, {"linux", "arm64"}, {"darwin", "arm64"}, {"windows", "amd64"}, {"windows", "arm64"}}

// The installers are named as desktop/scripts/build.mjs names them, one
// format for each system.
func TestPackageNameIsTheBuildsName(t *testing.T) {
	for _, c := range []struct{ goos, goarch, want string }{
		{"linux", "amd64", "cyfr-desktop_0.9.0-rc.1_linux_amd64.deb"},
		{"linux", "arm64", "cyfr-desktop_0.9.0-rc.1_linux_arm64.deb"},
		{"darwin", "arm64", "cyfr-desktop_0.9.0-rc.1_darwin_arm64.dmg"},
		{"windows", "amd64", "cyfr-desktop_0.9.0-rc.1_windows_amd64.msi"},
		{"windows", "arm64", "cyfr-desktop_0.9.0-rc.1_windows_arm64.msi"},
	} {
		if got := PackageName("0.9.0-rc.1", c.goos, c.goarch); got != c.want {
			t.Errorf("PackageName %s %s = %q, want %q", c.goos, c.goarch, got, c.want)
		}
	}
}

// The installer a signed checksums.txt names answers its own bytes, for
// each of the five, for a release and a pre-release alike.
func TestFetchPackageAnswersTheVerifiedPackage(t *testing.T) {
	for _, version := range []string{"0.9.0", "0.9.0-rc.1"} {
		r := newBinaryRelease(t, version)
		r.serve(t)
		for _, p := range installers {
			goos, goarch := p[0], p[1]
			got, err := signedPackage(version, goos, goarch)
			if err != nil {
				t.Fatalf("FetchPackage %s %s %s: %v", version, goos, goarch, err)
			}
			if want := "the app's installer " + goos + " " + goarch + " " + version; string(got) != want {
				t.Errorf("FetchPackage %s %s %s answered %q, want %q", version, goos, goarch, got, want)
			}
		}
	}
}

// An unsigned, wrong or missing package is refused, and none of it answered.
func TestFetchPackageRefusesUnsignedWrongOrMissing(t *testing.T) {
	const version = "0.9.0"
	amd, arm := PackageName(version, "linux", "amd64"), PackageName(version, "linux", "arm64")
	msi := PackageName(version, "windows", "amd64")
	cases := []struct {
		name       string
		asked      string
		unverified bool
		edit       func(t *testing.T, r *binaryRelease)
	}{
		{"changed after signing", version, true, func(t *testing.T, r *binaryRelease) {
			r.assets[amd] = []byte("attacker")
		}},
		{"the other architecture's installer", version, true, func(t *testing.T, r *binaryRelease) {
			r.assets[amd] = r.assets[arm]
		}},
		{"another system's installer", version, true, func(t *testing.T, r *binaryRelease) {
			r.assets[amd] = r.assets[msi]
		}},
		{"checksums.txt changed after signing", version, true, func(t *testing.T, r *binaryRelease) {
			r.assets[amd] = []byte("attacker")
			r.assets["checksums.txt"] = []byte(fmt.Sprintf("%x  %s\n", sha256.Sum256(r.assets[amd]), amd))
		}},
		{"signed by another workflow", version, true, func(t *testing.T, r *binaryRelease) {
			r.signChecksums(t, "https://github.com/cyfrworks/cyfr/.github/workflows/test.yml@refs/tags/0.9.0", Issuer)
		}},
		{"signed for another tag", version, true, func(t *testing.T, r *binaryRelease) {
			r.signChecksums(t, Identity("0.8.0"), Issuer)
		}},
		{"a bundle that is not a bundle", version, true, func(t *testing.T, r *binaryRelease) {
			r.assets["checksums.txt"+BundleSuffix] = []byte("not a bundle")
		}},
		{"a release with no installer for this system", version, true, func(t *testing.T, r *binaryRelease) {
			delete(r.assets, amd)
			r.signChecksums(t, Identity(version), Issuer)
		}},
		{"not a release version", "0.9", true, func(*testing.T, *binaryRelease) {}},
		{"unsigned", version, false, func(t *testing.T, r *binaryRelease) {
			delete(r.assets, "checksums.txt"+BundleSuffix)
		}},
		{"named and missing", version, false, func(t *testing.T, r *binaryRelease) {
			delete(r.assets, amd)
		}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			r := newBinaryRelease(t, version)
			c.edit(t, r)
			r.serve(t)
			got, err := signedPackage(c.asked, "linux", "amd64")
			if got != nil {
				t.Errorf("FetchPackage answered %d bytes", len(got))
			}
			switch {
			case err == nil:
				t.Error("FetchPackage refused nothing")
			case c.unverified && !errors.Is(err, ErrUnverified):
				t.Errorf("FetchPackage = %v, want ErrUnverified", err)
			case !c.unverified && !strings.Contains(err.Error(), "404"):
				t.Errorf("FetchPackage = %v, want a 404 refusal", err)
			}
		})
	}
}

// A package that changed after its sum was read, between the question
// and the download, is refused, and none of it answered.
func TestFetchPackageRefusesAPackageChangedAfterItsSumWasRead(t *testing.T) {
	const version = "0.9.0"
	r := newBinaryRelease(t, version)
	r.serve(t)
	sum, err := PackageChecksum(context.Background(), version, "windows", "amd64")
	if err != nil {
		t.Fatal(err)
	}
	r.assets[PackageName(version, "windows", "amd64")] = []byte("attacker")
	r.serve(t)
	if got, err := FetchPackage(context.Background(), version, "windows", "amd64", sum); got != nil || !errors.Is(err, ErrUnverified) {
		t.Errorf("FetchPackage = %d bytes, %v; want ErrUnverified and none", len(got), err)
	}
}

// The release sums, and attaches, exactly the CYFR app's five installers,
// each by the name FetchPackage asks for (PackageName).
func TestTheReleaseShipsTheNamesFetchPackageAsks(t *testing.T) {
	raw, err := os.ReadFile("../../.goreleaser.yml")
	if err != nil {
		t.Fatal(err)
	}
	type files struct {
		Extra []struct {
			Glob string `yaml:"glob"`
		} `yaml:"extra_files"`
	}
	var config struct {
		Checksum files `yaml:"checksum"`
		Release  files `yaml:"release"`
	}
	if err := yaml.Unmarshal(raw, &config); err != nil {
		t.Fatal(err)
	}
	const version = "0.9.0-rc.1"
	var want []string
	for _, p := range installers {
		want = append(want, PackageName(version, p[0], p[1]))
	}
	for where, list := range map[string]files{"checksum": config.Checksum, "release": config.Release} {
		var got []string
		for _, f := range list.Extra {
			if name, ok := strings.CutPrefix(f.Glob, "{{ .Env.RELEASE_PACKAGES_DIR }}/"); ok {
				got = append(got, strings.ReplaceAll(name, "{{ .Version }}", version))
			}
		}
		if !slices.Equal(got, want) {
			t.Errorf(".goreleaser.yml's %s names the packages %q, want %q", where, got, want)
		}
	}
}
