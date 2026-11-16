// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

import (
	"archive/zip"
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

// source serves a list naming one stable version, as Chrome for
// Testing's does, and the archive of its chrome build where the storage
// holds it, ranges answered as a storage answers them, counting what it is
// asked for and keeping each archive request's range.
type source struct {
	mu          sync.Mutex
	version     string
	list        string // when set, the list says this in place of the version
	archive     []byte
	cut         int  // when set, the next archive's body stops after this many bytes
	ignoreRange bool // when set, a range is answered with the whole archive
	hold        chan struct{}
	holding     chan struct{}
	asked       map[string]int
	ranges      []string
	server      *httptest.Server
}

func newSource(t *testing.T, version string) *source {
	t.Helper()
	s := &source{version: version, archive: chromeArchive(t, "linux64"), asked: map[string]int{}}
	s.server = httptest.NewServer(http.HandlerFunc(s.serve))
	t.Cleanup(s.server.Close)
	return s
}

func archivePath(version string) string { return "/" + version + "/linux64/chrome-linux64.zip" }

func (s *source) serve(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	s.asked[r.URL.Path]++
	version, list, body, cut, ignoreRange, hold := s.version, s.list, s.archive, s.cut, s.ignoreRange, s.hold
	if r.URL.Path == archivePath(version) {
		s.ranges = append(s.ranges, r.Header.Get("Range"))
		s.cut = 0
	}
	s.mu.Unlock()
	switch r.URL.Path {
	case "/LATEST_RELEASE_STABLE":
		if list != "" {
			_, _ = io.WriteString(w, list)
			return
		}
		_, _ = io.WriteString(w, version)
	case archivePath(version):
		whole := func() {
			w.Header().Set("Content-Length", fmt.Sprint(len(body)))
			w.WriteHeader(http.StatusOK)
		}
		switch {
		case cut > 0:
			// The length is the whole archive's; the body ends early, as a
			// download cut off does.
			whole()
			_, _ = w.Write(body[:cut])
		case hold != nil:
			whole()
			_, _ = w.Write(body[:len(body)/2])
			w.(http.Flusher).Flush()
			close(s.holding)
			<-hold
			_, _ = w.Write(body[len(body)/2:])
		case ignoreRange:
			whole()
			_, _ = w.Write(body)
		default:
			http.ServeContent(w, r, "chrome-linux64.zip", time.Time{}, bytes.NewReader(body))
		}
	default:
		http.NotFound(w, r)
	}
}

func (s *source) count(path string) int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.asked[path]
}

// chromeArchive is a chrome build's archive as Chrome for Testing packs
// it: a folder chrome-<platform> holding an executable chrome and a link.
func chromeArchive(t *testing.T, platform string) []byte {
	t.Helper()
	var buf bytes.Buffer
	z := zip.NewWriter(&buf)
	add := func(name string, mode os.FileMode, body string) {
		h := &zip.FileHeader{Name: name, Method: zip.Deflate}
		h.SetMode(mode)
		w, err := z.CreateHeader(h)
		if err != nil {
			t.Fatal(err)
		}
		_, _ = io.WriteString(w, body)
	}
	dir := "chrome-" + platform + "/"
	add(dir, os.ModeDir|0o755, "")
	add(dir+"chrome", 0o755, "#!/bin/sh\necho chrome\n")
	add(dir+"locales/en-US.pak", 0o644, "pak")
	add(dir+"chrome-wrapper", os.ModeSymlink|0o777, "chrome")
	if err := z.Close(); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

// homeStore is a store in a fresh home, fetched from list, on a clock the
// test moves.
func homeStore(t *testing.T, base string, now *time.Time) *store {
	t.Helper()
	s, err := newStore(t.TempDir(), base+"/LATEST_RELEASE_STABLE", base)
	if err != nil {
		t.Fatal(err)
	}
	s.platform = "linux64"
	s.now = func() time.Time { return *now }
	return s
}

// start is one start of the driver in the store's home: the Chrome it
// would run, its lock let go at once.
func start(s *store, log io.Writer) (string, error) {
	path, release, err := s.chrome(context.Background(), log)
	if release != nil {
		release()
	}
	return path, err
}

func partialBytes(t *testing.T, s *store, version string) int64 {
	t.Helper()
	info, err := os.Stat(filepath.Join(s.dir, ".partial-"+version+".zip"))
	if err != nil {
		return -1
	}
	return info.Size()
}

func staged(t *testing.T, s *store) []string {
	t.Helper()
	matches, err := filepath.Glob(filepath.Join(s.dir, ".staging-*"))
	if err != nil {
		t.Fatal(err)
	}
	return matches
}

func versions(t *testing.T, s *store) []string {
	t.Helper()
	entries, err := os.ReadDir(filepath.Join(s.dir, "versions"))
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, e := range entries {
		names = append(names, e.Name())
	}
	return names
}

func TestTheFirstStartFetchesAndPublishesAWholeChrome(t *testing.T) {
	src := newSource(t, "157.0.8103.78")
	now := time.Date(2026, 11, 16, 9, 0, 0, 0, time.UTC)
	s := homeStore(t, src.server.URL, &now)

	path, err := start(s, io.Discard)
	if err != nil {
		t.Fatal(err)
	}
	if want := filepath.Join(s.dir, "versions", "157.0.8103.78", "chrome"); path != want || !executable(path) {
		t.Fatalf("chrome is %s (executable %v), want %s", path, executable(path), want)
	}
	if link, err := os.Readlink(filepath.Join(s.dir, "versions", "157.0.8103.78", "chrome-wrapper")); err != nil || link != "chrome" {
		t.Fatalf("the archive's link reads %q, %v", link, err)
	}
	if left := staged(t, s); len(left) != 0 {
		t.Fatalf("a fetch left %v", left)
	}
	if src.count("/LATEST_RELEASE_STABLE") != 1 || src.count(archivePath("157.0.8103.78")) != 1 {
		t.Fatalf("the source was asked %v", src.asked)
	}
}

func TestARestartWithinADayFetchesNothing(t *testing.T) {
	src := newSource(t, "157.0.8103.78")
	now := time.Date(2026, 11, 16, 9, 0, 0, 0, time.UTC)
	s := homeStore(t, src.server.URL, &now)
	first, err := start(s, io.Discard)
	if err != nil {
		t.Fatal(err)
	}
	now = now.Add(23 * time.Hour)
	again, err := start(s, io.Discard)
	if err != nil || again != first {
		t.Fatalf("the restart starts %s (%v), want %s", again, err, first)
	}
	if src.count("/LATEST_RELEASE_STABLE") != 1 || src.count(archivePath("157.0.8103.78")) != 1 {
		t.Fatalf("the restart asked the source: %v", src.asked)
	}
}

func TestADayLaterANewerStableReplacesTheOldOnceWhole(t *testing.T) {
	src := newSource(t, "157.0.8103.78")
	now := time.Date(2026, 11, 16, 9, 0, 0, 0, time.UTC)
	s := homeStore(t, src.server.URL, &now)
	if _, err := start(s, io.Discard); err != nil {
		t.Fatal(err)
	}

	// A day later the list still names the same stable: nothing is fetched.
	now = now.Add(24 * time.Hour)
	if _, err := start(s, io.Discard); err != nil {
		t.Fatal(err)
	}
	if src.count("/LATEST_RELEASE_STABLE") != 2 || src.count(archivePath("157.0.8103.78")) != 1 {
		t.Fatalf("an unchanged stable was fetched again: %v", src.asked)
	}

	// Another day, a newer stable: fetched, started, and the old one gone.
	src.mu.Lock()
	src.version = "158.0.8200.10"
	src.mu.Unlock()
	now = now.Add(24 * time.Hour)
	path, err := start(s, io.Discard)
	if err != nil {
		t.Fatal(err)
	}
	if want := filepath.Join(s.dir, "versions", "158.0.8200.10", "chrome"); path != want {
		t.Fatalf("chrome is %s, want %s", path, want)
	}
	if got := versions(t, s); len(got) != 1 || got[0] != "158.0.8200.10" {
		t.Fatalf("the home holds %v", got)
	}
}

func TestAnUnreachableSourceWithNoChromeIsNotDownloaded(t *testing.T) {
	gone := httptest.NewServer(http.NotFoundHandler())
	base := gone.URL
	gone.Close()
	now := time.Date(2026, 11, 16, 9, 0, 0, 0, time.UTC)
	s := homeStore(t, base, &now)

	var said bytes.Buffer
	_, err := start(s, &said)
	if !errors.Is(err, errNotDownloaded) || err.Error() != "The browser could not be downloaded; try again in a moment." {
		t.Fatalf("an unreachable source answers %v", err)
	}
	if got := versions(t, s); len(got) != 0 {
		t.Fatalf("the home holds %v", got)
	}
	if left := staged(t, s); len(left) != 0 || said.Len() == 0 {
		t.Fatalf("staging %v, said %q", left, said.String())
	}
}

func TestAnUnreachableSourceWithAChromeStartsIt(t *testing.T) {
	src := newSource(t, "157.0.8103.78")
	now := time.Date(2026, 11, 16, 9, 0, 0, 0, time.UTC)
	s := homeStore(t, src.server.URL, &now)
	first, err := start(s, io.Discard)
	if err != nil {
		t.Fatal(err)
	}
	src.server.Close()
	now = now.Add(48 * time.Hour)
	path, err := start(s, io.Discard)
	if err != nil || path != first {
		t.Fatalf("with its source gone the home starts %s (%v), want %s", path, err, first)
	}
	// The failed check counts: the next start within a day asks nothing.
	if s.due() {
		t.Fatal("a check that was not answered is asked again within the day")
	}
}

func TestAnArchiveWholeAtItsLengthThatDoesNotReadIsNeverPublished(t *testing.T) {
	src := newSource(t, "157.0.8103.78")
	src.archive = src.archive[:len(src.archive)/2]
	now := time.Date(2026, 11, 16, 9, 0, 0, 0, time.UTC)
	s := homeStore(t, src.server.URL, &now)
	if _, err := start(s, io.Discard); !errors.Is(err, errNotDownloaded) {
		t.Fatalf("a truncated archive answers %v", err)
	}
	if got := versions(t, s); len(got) != 0 {
		t.Fatalf("the home holds %v", got)
	}
	if left := staged(t, s); len(left) != 0 || partialBytes(t, s, "157.0.8103.78") != -1 {
		t.Fatalf("a failed fetch left %v and a partial of %d bytes", left, partialBytes(t, s, "157.0.8103.78"))
	}
}

func TestADownloadCutAtHalfResumesAndPublishes(t *testing.T) {
	src := newSource(t, "157.0.8103.78")
	half := len(src.archive) / 2
	src.cut = half
	now := time.Date(2026, 11, 16, 9, 0, 0, 0, time.UTC)
	s := homeStore(t, src.server.URL, &now)
	if _, err := start(s, io.Discard); !errors.Is(err, errStillDownloading) ||
		err.Error() != "The browser is still downloading; try again in a moment." {
		t.Fatalf("a download cut at half answers %v", err)
	}
	if got := partialBytes(t, s, "157.0.8103.78"); got != int64(half) {
		t.Fatalf("the partial holds %d bytes, want %d", got, half)
	}

	// The next start, within the day, takes it up from where it stopped.
	now = now.Add(time.Minute)
	path, err := start(s, io.Discard)
	if err != nil || !executable(path) {
		t.Fatalf("the resumed download gave %s (%v)", path, err)
	}
	if want := []string{"", fmt.Sprintf("bytes=%d-", half)}; fmt.Sprint(src.ranges) != fmt.Sprint(want) {
		t.Fatalf("the archive was asked for %q, want %q", src.ranges, want)
	}
	if partialBytes(t, s, "157.0.8103.78") != -1 || len(staged(t, s)) != 0 {
		t.Fatal("a published version left its partial or staging")
	}
}

func TestAServerThatIgnoresTheRangeStartsOverAndStillPublishesWhole(t *testing.T) {
	src := newSource(t, "157.0.8103.78")
	src.cut = len(src.archive) / 3
	now := time.Date(2026, 11, 16, 9, 0, 0, 0, time.UTC)
	s := homeStore(t, src.server.URL, &now)
	if _, err := start(s, io.Discard); !errors.Is(err, errStillDownloading) {
		t.Fatalf("a cut download answers %v", err)
	}
	src.mu.Lock()
	src.ignoreRange = true
	src.mu.Unlock()
	path, err := start(s, io.Discard)
	if err != nil || !executable(path) {
		t.Fatalf("a whole answer to a range gave %s (%v)", path, err)
	}
	if len(src.ranges) != 2 || src.ranges[1] == "" {
		t.Fatalf("the second start asked for %q", src.ranges)
	}
	if partialBytes(t, s, "157.0.8103.78") != -1 {
		t.Fatal("the partial outlived its version's publishing")
	}
}

func TestAPartialOfAVersionNoLongerCurrentIsDiscarded(t *testing.T) {
	src := newSource(t, "158.0.8200.10")
	now := time.Date(2026, 11, 16, 9, 0, 0, 0, time.UTC)
	s := homeStore(t, src.server.URL, &now)
	if err := os.MkdirAll(s.dir, 0o700); err != nil {
		t.Fatal(err)
	}
	stale := filepath.Join(s.dir, ".partial-157.0.8103.78.zip")
	if err := os.WriteFile(stale, []byte("a part of an older stable"), 0o600); err != nil {
		t.Fatal(err)
	}
	path, err := start(s, io.Discard)
	if err != nil || path != filepath.Join(s.dir, "versions", "158.0.8200.10", "chrome") {
		t.Fatalf("the current stable gave %s (%v)", path, err)
	}
	if _, err := os.Stat(stale); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("the stale partial stands: %v", err)
	}
	if src.count(archivePath("157.0.8103.78")) != 0 {
		t.Fatal("the stale version was fetched")
	}
}

func TestTwoStartsAtOnceDoNotWriteOnePartial(t *testing.T) {
	src := newSource(t, "157.0.8103.78")
	src.hold, src.holding = make(chan struct{}), make(chan struct{})
	now := time.Date(2026, 11, 16, 9, 0, 0, 0, time.UTC)
	home := t.TempDir()
	first, second := homeStore(t, src.server.URL, &now), homeStore(t, src.server.URL, &now)
	first.dir, second.dir = filepath.Join(home, "cyfr-browser"), filepath.Join(home, "cyfr-browser")

	done := make(chan error, 1)
	go func() {
		_, err := start(first, io.Discard)
		done <- err
	}()
	<-src.holding
	// The first start holds the lock and is mid-download: the second
	// fetches nothing and says the browser is still downloading.
	if _, err := start(second, io.Discard); !errors.Is(err, errStillDownloading) {
		t.Fatalf("the second start answers %v", err)
	}
	if got := src.count(archivePath("157.0.8103.78")) + src.count("/LATEST_RELEASE_STABLE"); got != 2 {
		t.Fatalf("the second start asked the source: %v", src.asked)
	}
	close(src.hold)
	if err := <-done; err != nil {
		t.Fatalf("the first start answers %v", err)
	}
	// With a Chrome in the home, a start that finds the lock held starts
	// it and fetches nothing.
	release, held, err := first.lock()
	if err != nil || !held {
		t.Fatalf("the lock: %v %v", held, err)
	}
	path, err := start(second, io.Discard)
	release()
	if err != nil || !executable(path) || len(src.ranges) != 1 {
		t.Fatalf("a start beside a held lock gave %s (%v), the archive asked %v", path, err, src.ranges)
	}
}

func TestTheListDecidesAVersionNumberAndNothingElse(t *testing.T) {
	now := time.Date(2026, 11, 16, 9, 0, 0, 0, time.UTC)

	// What the list says is not followed and is no version: nothing is
	// fetched, from the storage or from where the list points.
	elsewhere := newSource(t, "157.0.8103.78")
	for _, said := range []string{
		`{"channels":{"Stable":{"version":"157.0.8103.78","downloads":{"chrome":[{"platform":"linux64","url":"` +
			elsewhere.server.URL + archivePath("157.0.8103.78") + `"}]}}}}`,
		"157.0.8103.78 " + elsewhere.server.URL + archivePath("157.0.8103.78"),
		"157.0.8103.78a", "../../157.0.8103.78", "157.0.8103", " ", "157.0.8103.78\n\n",
	} {
		src := newSource(t, "157.0.8103.78")
		src.list = said
		s := homeStore(t, src.server.URL, &now)
		if _, err := start(s, io.Discard); !errors.Is(err, errNotDownloaded) {
			t.Fatalf("a list saying %q answers %v", said, err)
		}
		if src.count(archivePath("157.0.8103.78")) != 0 || elsewhere.count(archivePath("157.0.8103.78")) != 0 {
			t.Fatalf("a list saying %q was followed: %v %v", said, src.asked, elsewhere.asked)
		}
	}

	// The version, with the line's end the list may close it with: its
	// archive is fetched from the address the driver builds on the storage.
	src := newSource(t, "157.0.8103.78")
	src.list = "157.0.8103.78\n"
	s := homeStore(t, src.server.URL, &now)
	if _, err := start(s, io.Discard); err != nil {
		t.Fatal(err)
	}
	if src.count(archivePath("157.0.8103.78")) != 1 {
		t.Fatalf("the built address was not fetched: %v", src.asked)
	}
	if got, want := s.archive("157.0.8103.78"), src.server.URL+archivePath("157.0.8103.78"); got != want {
		t.Fatalf("the archive is at %s, want %s", got, want)
	}
}

func TestALowerVersionReplacesNothing(t *testing.T) {
	src := newSource(t, "158.0.8200.10")
	now := time.Date(2026, 11, 16, 9, 0, 0, 0, time.UTC)
	s := homeStore(t, src.server.URL, &now)
	first, err := start(s, io.Discard)
	if err != nil {
		t.Fatal(err)
	}
	src.mu.Lock()
	src.version = "157.0.8103.78"
	src.mu.Unlock()
	now = now.Add(48 * time.Hour)
	again, err := start(s, io.Discard)
	if err != nil || again != first {
		t.Fatalf("a lower stable gave %s (%v), want %s", again, err, first)
	}
	if src.count(archivePath("157.0.8103.78")) != 0 || src.count("/LATEST_RELEASE_STABLE") != 2 {
		t.Fatalf("a lower stable was fetched: %v", src.asked)
	}
	if got := versions(t, s); len(got) != 1 || got[0] != "158.0.8200.10" {
		t.Fatalf("the home holds %v", got)
	}
}

func TestAnArchiveReachingOutsideItsFolderIsRefused(t *testing.T) {
	for _, name := range []string{"../escaped", "/etc/escaped", "chrome-linux64/../../escaped"} {
		var buf bytes.Buffer
		z := zip.NewWriter(&buf)
		if _, err := z.Create(name); err != nil {
			t.Fatal(err)
		}
		_ = z.Close()
		dir := t.TempDir()
		archive := filepath.Join(dir, "a.zip")
		if err := os.WriteFile(archive, buf.Bytes(), 0o600); err != nil {
			t.Fatal(err)
		}
		if err := unzip(archive, filepath.Join(dir, "root")); err == nil {
			t.Fatalf("%s was unpacked", name)
		}
		if _, err := os.Stat(filepath.Join(dir, "escaped")); err == nil {
			t.Fatalf("%s reached outside the folder", name)
		}
	}
}

func TestPlatformsAndVersions(t *testing.T) {
	for arch, want := range map[string]string{"amd64": "linux64", "arm64": "linux-arm64"} {
		if got, err := platformOf(arch); err != nil || got != want {
			t.Fatalf("%s is %q (%v)", arch, got, err)
		}
	}
	if _, err := platformOf("riscv64"); err == nil {
		t.Fatal("riscv64 has a build")
	}
	if !newer("158.0.1.2", "157.9.9.9") || newer("157.0.8103.78", "157.0.8103.78") || !newer("157.0.8103.100", "157.0.8103.78") {
		t.Fatal("versions compare by their numbers")
	}
}
