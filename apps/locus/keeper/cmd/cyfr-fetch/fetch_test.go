// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"crypto/sha512"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"
)

// TestMain runs the command's main in place of the tests when the
// environment asks, so a test can run the command as a process of its own,
// and stands in for an installed program when run as one, writing the
// arguments it was given and the environment's mark.
func TestMain(m *testing.M) {
	if os.Args[0] == "agy" {
		fmt.Print(strings.Join(os.Args, "\x00") + "\x00mark=" + os.Getenv("CYFR_FETCH_TEST_MARK"))
		os.Exit(0)
	}
	if os.Getenv("CYFR_FETCH_TEST_MAIN") == "1" {
		os.Args = append([]string{"cyfr-fetch"}, os.Args[1:]...)
		main()
		os.Exit(0)
	}
	os.Exit(m.Run())
}

const script = "#!/bin/sh\necho agy\n"

type entry struct {
	header tar.Header
	body   string
}

func tarGz(t *testing.T, entries ...entry) []byte {
	t.Helper()
	var buf bytes.Buffer
	gz := gzip.NewWriter(&buf)
	tw := tar.NewWriter(gz)
	for _, e := range entries {
		h := e.header
		h.Size = int64(len(e.body))
		if err := tw.WriteHeader(&h); err != nil {
			t.Fatal(err)
		}
		if _, err := io.WriteString(tw, e.body); err != nil {
			t.Fatal(err)
		}
	}
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}
	if err := gz.Close(); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func file(name, body string) entry {
	return entry{tar.Header{Name: name, Typeflag: tar.TypeReg, Mode: 0o755}, body}
}

func sum(b []byte) string {
	s := sha512.Sum512(b)
	return hex.EncodeToString(s[:])
}

// origin is a TLS server serving each path's bytes, counting its hits.
type origin struct {
	server *httptest.Server
	hits   atomic.Int64
}

func serveFiles(t *testing.T, files map[string][]byte) *origin {
	t.Helper()
	o := &origin{}
	o.server = httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		o.hits.Add(1)
		if target, ok := strings.CutPrefix(r.URL.Path, "/redirect/"); ok {
			http.Redirect(w, r, "http://"+target, http.StatusFound)
			return
		}
		body, ok := files[r.URL.Path]
		if !ok {
			http.NotFound(w, r)
			return
		}
		_, _ = w.Write(body)
	}))
	t.Cleanup(o.server.Close)
	return o
}

func (o *origin) fetcher(notice io.Writer) fetcher {
	return fetcher{client: o.server.Client(), notice: notice, maxDownload: maxDownload, maxProgram: maxProgram, maxEntries: maxEntries}
}

func (o *origin) pinned(path string, body []byte) program {
	return program{name: "agy", version: "1.5.16", url: o.server.URL + path, sum: sum(body)}
}

// folder is the version folder of agy 1.5.16 pinned to the SHA-512 sum.
func folder(home, sum string) string {
	return filepath.Join(home, ".local", "share", "cyfr", "programs", "agy", "1.5.16-"+sum)
}

// names is the folder's entries; none when it does not exist.
func names(t *testing.T, dir string) []string {
	t.Helper()
	entries, err := os.ReadDir(dir)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		t.Fatal(err)
	}
	var out []string
	for _, e := range entries {
		out = append(out, e.Name())
	}
	return out
}

func TestATarballIsFetchedVerifiedAndInstalledOnce(t *testing.T) {
	archive := tarGz(t, file("cli_linux_x64", script))
	o := serveFiles(t, map[string][]byte{"/cli.tar.gz": archive})
	home := t.TempDir()
	var notice bytes.Buffer
	p := o.pinned("/cli.tar.gz", archive)

	path, err := o.fetcher(&notice).install(home, p)
	if err != nil {
		t.Fatalf("install: %v", err)
	}
	if path != filepath.Join(folder(home, p.sum), "agy") {
		t.Fatalf("installed at %s", path)
	}
	got, err := os.ReadFile(path)
	if err != nil || string(got) != script {
		t.Fatalf("the archive's one file: %q %v", got, err)
	}
	info, _ := os.Stat(path)
	if info.Mode() != 0o755 {
		t.Fatalf("mode %v", info.Mode())
	}
	for dir := folder(home, p.sum); dir != home; dir = filepath.Dir(dir) {
		if info, _ := os.Stat(dir); info.Mode().Perm() != 0o700 {
			t.Fatalf("%s: mode %v", dir, info.Mode())
		}
	}
	if n := names(t, folder(home, p.sum)); len(n) != 1 || n[0] != "agy" {
		t.Fatalf("the folder holds the program alone: %v", n)
	}
	if notice.String() != "cyfr-fetch: fetching agy 1.5.16\n" {
		t.Fatalf("notice %q", notice.String())
	}

	again, err := o.fetcher(&notice).install(home, p)
	if err != nil || again != path {
		t.Fatalf("second run: %s %v", again, err)
	}
	if hits := o.hits.Load(); hits != 1 {
		t.Fatalf("an installed program is not fetched again: %d hits", hits)
	}
	if notice.String() != "cyfr-fetch: fetching agy 1.5.16\n" {
		t.Fatalf("a second run says nothing: %q", notice.String())
	}
}

func TestAPlainDownloadIsTheProgram(t *testing.T) {
	body := []byte(script)
	o := serveFiles(t, map[string][]byte{"/agy": body})
	home := t.TempDir()
	path, err := o.fetcher(io.Discard).install(home, o.pinned("/agy", body))
	if err != nil {
		t.Fatalf("install: %v", err)
	}
	got, _ := os.ReadFile(path)
	info, _ := os.Stat(path)
	if string(got) != script || info.Mode() != 0o755 {
		t.Fatalf("the download as the program: %q %v", got, info.Mode())
	}
	if n := names(t, folder(home, sum(body))); len(n) != 1 {
		t.Fatalf("no temporary file stays: %v", n)
	}
}

func TestAChecksumMismatchInstallsNothing(t *testing.T) {
	archive := tarGz(t, file("cli", script))
	o := serveFiles(t, map[string][]byte{"/cli.tar.gz": archive})
	home := t.TempDir()
	p := o.pinned("/cli.tar.gz", archive)
	p.sum = sum([]byte("another"))
	_, err := o.fetcher(io.Discard).install(home, p)
	if err == nil || !strings.Contains(err.Error(), "checksum") || !strings.Contains(err.Error(), "nothing was installed") {
		t.Fatalf("a mismatch: %v", err)
	}
	if n := names(t, folder(home, p.sum)); len(n) != 0 {
		t.Fatalf("nothing stays: %v", n)
	}
}

func TestATarballOfOtherThanOneRegularFileIsRefused(t *testing.T) {
	for label, archive := range map[string][]byte{
		"two files": tarGz(t, file("a", script), file("b", script)),
		"a folder":  tarGz(t, entry{tar.Header{Name: "bin/", Typeflag: tar.TypeDir, Mode: 0o755}, ""}),
		"a symlink": tarGz(t, entry{tar.Header{Name: "agy", Typeflag: tar.TypeSymlink, Linkname: "/bin/sh"}, ""}),
		"empty":     tarGz(t),
	} {
		o := serveFiles(t, map[string][]byte{"/cli.tgz": archive})
		home := t.TempDir()
		if _, err := o.fetcher(io.Discard).install(home, o.pinned("/cli.tgz", archive)); err == nil {
			t.Fatalf("%s: refused expected", label)
		}
		if n := names(t, folder(home, sum(archive))); len(n) != 0 {
			t.Fatalf("%s: nothing stays: %v", label, n)
		}
	}
}

func TestADownloadOrProgramPastItsBoundIsRefused(t *testing.T) {
	archive := tarGz(t, file("cli", strings.Repeat("x", 4096)))
	plain := []byte(strings.Repeat("x", 4096))
	o := serveFiles(t, map[string][]byte{"/cli.tar.gz": archive, "/agy": plain})
	for label, c := range map[string]struct {
		limits func(*fetcher)
		path   string
		body   []byte
	}{
		"download":       {func(f *fetcher) { f.maxDownload = int64(len(archive)) - 1 }, "/cli.tar.gz", archive},
		"extracted file": {func(f *fetcher) { f.maxProgram = 4095 }, "/cli.tar.gz", archive},
		"plain program":  {func(f *fetcher) { f.maxProgram = 4095 }, "/agy", plain},
	} {
		home := t.TempDir()
		f := o.fetcher(io.Discard)
		c.limits(&f)
		if _, err := f.install(home, o.pinned(c.path, c.body)); err == nil || !strings.Contains(err.Error(), "larger than") {
			t.Fatalf("%s: refused expected, got %v", label, err)
		}
		if n := names(t, folder(home, sum(c.body))); len(n) != 0 {
			t.Fatalf("%s: nothing stays: %v", label, n)
		}
	}
}

func TestARedirectToPlainHTTPIsRefused(t *testing.T) {
	o := serveFiles(t, map[string][]byte{})
	home := t.TempDir()
	_, err := o.fetcher(io.Discard).install(home, program{name: "agy", version: "1.5.16", url: o.server.URL + "/redirect/example.invalid/agy", sum: sum(nil)})
	if err == nil || !strings.Contains(err.Error(), "https") {
		t.Fatalf("a redirect to http: %v", err)
	}
}

func TestALeftoverTemporaryFileIsRemoved(t *testing.T) {
	body := []byte(script)
	o := serveFiles(t, map[string][]byte{"/agy": body})
	home := t.TempDir()
	if err := os.MkdirAll(folder(home, sum(body)), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(folder(home, sum(body)), tempPrefix+"interrupted"), []byte("part"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := o.fetcher(io.Discard).install(home, o.pinned("/agy", body)); err != nil {
		t.Fatalf("install: %v", err)
	}
	if n := names(t, folder(home, sum(body))); len(n) != 1 || n[0] != "agy" {
		t.Fatalf("the leftover is gone: %v", n)
	}
}

// A second first run waits on the folder's lock while the first installs,
// then runs what the first installed with no fetch of its own.
func TestASecondFirstRunWaitsForTheFirstsInstall(t *testing.T) {
	body := []byte(script)
	o := serveFiles(t, map[string][]byte{"/agy": body})
	home := t.TempDir()
	dir := folder(home, sum(body))
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	first, err := os.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer first.Close()
	if err := syscall.Flock(int(first.Fd()), syscall.LOCK_EX); err != nil {
		t.Fatal(err)
	}
	var info syscall.Stat_t
	if err := syscall.Fstat(int(first.Fd()), &info); err != nil {
		t.Fatal(err)
	}

	var wg sync.WaitGroup
	var path string
	var installErr error
	wg.Add(1)
	go func() {
		defer wg.Done()
		path, installErr = o.fetcher(io.Discard).install(home, o.pinned("/agy", body))
	}()
	// A bounded wait for the kernel to list the second run's lock as
	// blocked on the folder; sleep-ok: /proc/locks has no notification.
	waiting := fmt.Sprintf(":%d ", info.Ino)
	deadline := time.Now().Add(10 * time.Second)
	for {
		locks, _ := os.ReadFile("/proc/locks")
		blocked := false
		for _, line := range strings.Split(string(locks), "\n") {
			if strings.Contains(line, "-> FLOCK") && strings.Contains(line, waiting) {
				blocked = true
			}
		}
		if blocked {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the second run never waited on the folder's lock")
		}
		time.Sleep(10 * time.Millisecond) // sleep-ok: polling /proc/locks
	}
	if err := os.WriteFile(filepath.Join(dir, "agy"), []byte("#!/bin/sh\necho first\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	_ = syscall.Flock(int(first.Fd()), syscall.LOCK_UN)
	wg.Wait()
	if installErr != nil || path != filepath.Join(dir, "agy") {
		t.Fatalf("second run: %s %v", path, installErr)
	}
	if got, _ := os.ReadFile(path); string(got) != "#!/bin/sh\necho first\n" || o.hits.Load() != 0 {
		t.Fatalf("the first's install, unfetched: %q, %d hits", got, o.hits.Load())
	}
}

const hash = "3dee9f26e298156db673f6ce2a0f5dfed5b30006e04ceb9809c68070e7b717587b33a3da0f8bc2eda45af81a50bc8b14c82b28ae5832bcfe3e7fd49397117b31"

func TestArgumentsReadAsTheRowNamesThem(t *testing.T) {
	amd := "amd64=https://storage.example/linux-x64/cli.tar.gz#" + hash
	arm := "arm64=https://storage.example/linux-arm/cli.tar.gz#" + strings.ToUpper(hash)
	for label, c := range map[string]struct {
		args []string
		arch string
		url  string
		rest []string
	}{
		"amd64":          {[]string{"agy", "1.5.16", amd, arm}, "amd64", "https://storage.example/linux-x64/cli.tar.gz", nil},
		"arm64":          {[]string{"agy", "1.5.16", amd, arm}, "arm64", "https://storage.example/linux-arm/cli.tar.gz", nil},
		"after --":       {[]string{"agy", "1.5.16", amd, "--", "x=y", "--help"}, "amd64", "https://storage.example/linux-x64/cli.tar.gz", []string{"x=y", "--help"}},
		"after the last": {[]string{"agy", "1.5.16", amd, arm, "--help", "x=y"}, "amd64", "https://storage.example/linux-x64/cli.tar.gz", []string{"--help", "x=y"}},
	} {
		p, err := parse(c.args, c.arch)
		if err != nil {
			t.Fatalf("%s: %v", label, err)
		}
		if p.name != "agy" || p.version != "1.5.16" || p.url != c.url || p.sum != hash || fmt.Sprint(p.args) != fmt.Sprint(c.rest) {
			t.Fatalf("%s: %+v", label, p)
		}
	}
}

func TestNoDownloadForThisArchitectureIsAnError(t *testing.T) {
	_, err := parse([]string{"agy", "1.5.16", "amd64=https://storage.example/cli#" + hash}, "riscv64")
	var bad usageError
	if err == nil || !errors.As(err, &bad) || !strings.Contains(err.Error(), "riscv64") {
		t.Fatalf("no download for riscv64: %v", err)
	}
}

func TestBadArgumentsAreRefused(t *testing.T) {
	pair := "amd64=https://storage.example/cli#" + hash
	for _, args := range [][]string{
		{},
		{"agy"},
		{"agy", "1.5.16"},
		{"agy", "1.5.16", "--", "x"},
		{"agy", "1.5.16", "amd64=http://storage.example/cli#" + hash},
		{"agy", "1.5.16", "amd64=https:///cli#" + hash},
		{"agy", "1.5.16", "amd64=https://storage.example/cli#" + hash[:127]},
		{"agy", "1.5.16", "amd64=https://storage.example/cli#" + hash[:127] + "g"},
		{"agy", "1.5.16", "amd64=https://storage.example/cli"},
		{"agy", "1.5.16", pair, pair},
		{"Agy", "1.5.16", pair},
		{"../agy", "1.5.16", pair},
		{".agy", "1.5.16", pair},
		{strings.Repeat("a", 65), "1.5.16", pair},
		{"agy", "..", pair},
		{"agy", "1.5/16", pair},
		{"agy", strings.Repeat("1", 65), pair},
	} {
		_, err := parse(args, "amd64")
		var bad usageError
		if err == nil || !errors.As(err, &bad) {
			t.Fatalf("%q: a usage error expected, got %v", args, err)
		}
	}
}

// The command runs the installed program in its own place: argv[0] is
// the name, the program's arguments follow, the environment unchanged.
func TestTheCommandRunsAnInstalledProgramInItsPlace(t *testing.T) {
	home := t.TempDir()
	if err := os.MkdirAll(folder(home, hash), 0o700); err != nil {
		t.Fatal(err)
	}
	self, err := os.ReadFile("/proc/self/exe")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(folder(home, hash), "agy"), self, 0o755); err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(os.Args[0], "agy", "1.5.16", runtime.GOARCH+"=https://storage.example.invalid/cli.tar.gz#"+hash,
		"--", "--help", "x=y")
	cmd.Env = append(os.Environ(), "CYFR_FETCH_TEST_MAIN=1", "HOME="+home, "CYFR_FETCH_TEST_MARK=kept")
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("run: %v %s", err, stderr.String())
	}
	if string(out) != "agy\x00--help\x00x=y\x00mark=kept" {
		t.Fatalf("argv[0] the name, the program's arguments, the environment unchanged: %q", out)
	}
	if stderr.Len() != 0 {
		t.Fatalf("an installed program runs with no words: %q", stderr.String())
	}

	usage := exec.Command(os.Args[0], "agy")
	usage.Env = append(os.Environ(), "CYFR_FETCH_TEST_MAIN=1", "HOME="+home)
	var exit *exec.ExitError
	if err := usage.Run(); !errors.As(err, &exit) || exit.ExitCode() != 2 {
		t.Fatalf("a usage error exits 2: %v", err)
	}
}

func TestAChangedChecksumFetchesAnewIntoItsOwnFolder(t *testing.T) {
	old, renewed := []byte("#!/bin/sh\necho old\n"), []byte("#!/bin/sh\necho new\n")
	o := serveFiles(t, map[string][]byte{"/old": old, "/new": renewed})
	home := t.TempDir()
	first, err := o.fetcher(io.Discard).install(home, o.pinned("/old", old))
	if err != nil {
		t.Fatalf("first: %v", err)
	}
	second, err := o.fetcher(io.Discard).install(home, o.pinned("/new", renewed))
	if err != nil {
		t.Fatalf("second: %v", err)
	}
	if second != filepath.Join(folder(home, sum(renewed)), "agy") || first == second {
		t.Fatalf("another checksum, another folder: %s then %s", first, second)
	}
	if got, _ := os.ReadFile(second); string(got) != string(renewed) {
		t.Fatalf("the new pin's bytes run: %q", got)
	}
	if got, _ := os.ReadFile(first); string(got) != string(old) {
		t.Fatalf("the old pin's folder is its own: %q", got)
	}
	if hits := o.hits.Load(); hits != 2 {
		t.Fatalf("the new pin is fetched: %d hits", hits)
	}
}

// linked makes the folder at rel below home a link to a folder elsewhere,
// with every folder above it real, and answers the folder elsewhere.
func linked(t *testing.T, home, rel string) string {
	t.Helper()
	elsewhere := t.TempDir()
	at := filepath.Join(home, rel)
	if err := os.MkdirAll(filepath.Dir(at), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(elsewhere, at); err != nil {
		t.Fatal(err)
	}
	return elsewhere
}

func TestALinkedFolderOfTheInstallIsRefused(t *testing.T) {
	body := []byte(script)
	o := serveFiles(t, map[string][]byte{"/agy": body})
	for _, rel := range []string{
		".local",
		filepath.Join(".local", "share", "cyfr", "programs"),
		filepath.Join(".local", "share", "cyfr", "programs", "agy"),
		filepath.Join(".local", "share", "cyfr", "programs", "agy", "1.5.16-"+sum(body)),
	} {
		t.Run(rel, func(t *testing.T) {
			home := t.TempDir()
			elsewhere := linked(t, home, rel)
			_, err := o.fetcher(io.Discard).install(home, o.pinned("/agy", body))
			if err == nil || !strings.Contains(err.Error(), "is a link or not a folder of this user's own") {
				t.Fatalf("refused expected, got %v", err)
			}
			if n := names(t, elsewhere); len(n) != 0 {
				t.Fatalf("nothing is written through the link: %v", n)
			}
		})
	}
	if hits := o.hits.Load(); hits != 0 {
		t.Fatalf("a refused install fetches nothing: %d hits", hits)
	}
}

func TestAnInstalledProgramThatIsALinkIsRefused(t *testing.T) {
	body := []byte(script)
	o := serveFiles(t, map[string][]byte{"/agy": body})
	home := t.TempDir()
	elsewhere := filepath.Join(t.TempDir(), "agy")
	if err := os.WriteFile(elsewhere, body, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(folder(home, sum(body)), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(elsewhere, filepath.Join(folder(home, sum(body)), "agy")); err != nil {
		t.Fatal(err)
	}
	path, err := o.fetcher(io.Discard).install(home, o.pinned("/agy", body))
	if err == nil || path != "" || !strings.Contains(err.Error(), "is a link or not an executable file") {
		t.Fatalf("a linked program: refused expected, got %q %v", path, err)
	}
	if info, err := os.Lstat(filepath.Join(folder(home, sum(body)), "agy")); err != nil || info.Mode()&os.ModeSymlink == 0 || o.hits.Load() != 0 {
		t.Fatalf("the link is left as it is and nothing fetched: %v %v", info, err)
	}
}
