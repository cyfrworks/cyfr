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

// source serves a list naming one stable version and the archive of its
// chrome build, counting what it is asked for.
type source struct {
	mu       sync.Mutex
	version  string
	archive  []byte
	cut      int // when set, the archive's body stops after this many bytes
	asked    map[string]int
	server   *httptest.Server
	platform string
}

func newSource(t *testing.T, version string) *source {
	t.Helper()
	s := &source{version: version, archive: chromeArchive(t, "linux64"), asked: map[string]int{}, platform: "linux64"}
	s.server = httptest.NewServer(http.HandlerFunc(s.serve))
	t.Cleanup(s.server.Close)
	return s
}

func (s *source) serve(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.asked[r.URL.Path]++
	switch r.URL.Path {
	case "/list.json":
		fmt.Fprintf(w, `{"channels":{"Stable":{"version":%q,"downloads":{"chrome":[`+
			`{"platform":"mac-arm64","url":"%s/mac.zip"},{"platform":%q,"url":"%s/%s/chrome.zip"}]}}}}`,
			s.version, s.server.URL, s.platform, s.server.URL, s.version)
	case "/" + s.version + "/chrome.zip":
		body := s.archive
		if s.cut > 0 {
			// The length is the whole archive's; the body ends early, as a
			// download cut off does.
			w.Header().Set("Content-Length", fmt.Sprint(len(body)))
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write(body[:s.cut])
			return
		}
		_, _ = w.Write(body)
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
func homeStore(t *testing.T, list string, now *time.Time) *store {
	t.Helper()
	s, err := newStore(t.TempDir(), list)
	if err != nil {
		t.Fatal(err)
	}
	s.platform = "linux64"
	s.now = func() time.Time { return *now }
	return s
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
	s := homeStore(t, src.server.URL+"/list.json", &now)

	path, err := s.chrome(context.Background(), io.Discard)
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
	if src.count("/list.json") != 1 || src.count("/157.0.8103.78/chrome.zip") != 1 {
		t.Fatalf("the source was asked %v", src.asked)
	}
}

func TestARestartWithinADayFetchesNothing(t *testing.T) {
	src := newSource(t, "157.0.8103.78")
	now := time.Date(2026, 11, 16, 9, 0, 0, 0, time.UTC)
	s := homeStore(t, src.server.URL+"/list.json", &now)
	first, err := s.chrome(context.Background(), io.Discard)
	if err != nil {
		t.Fatal(err)
	}
	now = now.Add(23 * time.Hour)
	again, err := s.chrome(context.Background(), io.Discard)
	if err != nil || again != first {
		t.Fatalf("the restart starts %s (%v), want %s", again, err, first)
	}
	if src.count("/list.json") != 1 || src.count("/157.0.8103.78/chrome.zip") != 1 {
		t.Fatalf("the restart asked the source: %v", src.asked)
	}
}

func TestADayLaterANewerStableReplacesTheOldOnceWhole(t *testing.T) {
	src := newSource(t, "157.0.8103.78")
	now := time.Date(2026, 11, 16, 9, 0, 0, 0, time.UTC)
	s := homeStore(t, src.server.URL+"/list.json", &now)
	if _, err := s.chrome(context.Background(), io.Discard); err != nil {
		t.Fatal(err)
	}

	// A day later the list still names the same stable: nothing is fetched.
	now = now.Add(24 * time.Hour)
	if _, err := s.chrome(context.Background(), io.Discard); err != nil {
		t.Fatal(err)
	}
	if src.count("/list.json") != 2 || src.count("/157.0.8103.78/chrome.zip") != 1 {
		t.Fatalf("an unchanged stable was fetched again: %v", src.asked)
	}

	// Another day, a newer stable: fetched, started, and the old one gone.
	src.mu.Lock()
	src.version = "158.0.8200.10"
	src.mu.Unlock()
	now = now.Add(24 * time.Hour)
	path, err := s.chrome(context.Background(), io.Discard)
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
	list := gone.URL + "/list.json"
	gone.Close()
	now := time.Date(2026, 11, 16, 9, 0, 0, 0, time.UTC)
	s := homeStore(t, list, &now)

	var said bytes.Buffer
	_, err := s.chrome(context.Background(), &said)
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
	s := homeStore(t, src.server.URL+"/list.json", &now)
	first, err := s.chrome(context.Background(), io.Discard)
	if err != nil {
		t.Fatal(err)
	}
	src.server.Close()
	now = now.Add(48 * time.Hour)
	path, err := s.chrome(context.Background(), io.Discard)
	if err != nil || path != first {
		t.Fatalf("with its source gone the home starts %s (%v), want %s", path, err, first)
	}
	// The failed check counts: the next start within a day asks nothing.
	if s.due() {
		t.Fatal("a check that was not answered is asked again within the day")
	}
}

func TestATruncatedArchiveIsNeverPublished(t *testing.T) {
	src := newSource(t, "157.0.8103.78")
	src.cut = len(src.archive) / 2
	now := time.Date(2026, 11, 16, 9, 0, 0, 0, time.UTC)
	s := homeStore(t, src.server.URL+"/list.json", &now)
	if _, err := s.chrome(context.Background(), io.Discard); !errors.Is(err, errNotDownloaded) {
		t.Fatalf("a cut download answers %v", err)
	}

	// An archive whose length says what it holds, but cut: it does not read.
	src.cut = 0
	src.archive = src.archive[:len(src.archive)/2]
	if _, err := s.chrome(context.Background(), io.Discard); !errors.Is(err, errNotDownloaded) {
		t.Fatalf("a truncated archive answers %v", err)
	}
	if got := versions(t, s); len(got) != 0 {
		t.Fatalf("the home holds %v", got)
	}
	if left := staged(t, s); len(left) != 0 {
		t.Fatalf("a failed fetch left %v", left)
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
