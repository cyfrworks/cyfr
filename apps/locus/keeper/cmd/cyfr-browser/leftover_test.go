// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

func write(t *testing.T, path, text string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(text), 0o600); err != nil {
		t.Fatal(err)
	}
}

func exists(path string) bool {
	_, err := os.Lstat(path)
	return err == nil
}

// The fetched Chrome's folder goes whole; the profile, the temporary
// folder and anything else of the home stay as they were.
func TestLeftoversGoAndNothingElse(t *testing.T) {
	home := t.TempDir()
	for _, path := range []string{"cyfr-browser/versions/131.0.6778.85/chrome", "cyfr-browser/checked", "cyfr-browser/.lock",
		"cyfr-browser/.partial-132.0.6834.83.zip", "cyfr-browser/.staging-1234/unpacked/chrome"} {
		write(t, filepath.Join(home, path), "fetched")
	}
	write(t, filepath.Join(home, "chrome/Default/Sessions/Session_1"), "the profile")
	write(t, filepath.Join(home, "tmp/kept"), "kept")
	write(t, filepath.Join(home, "cyfr-browser-notes"), "kept")
	var log bytes.Buffer
	removeLeftovers(home, &log)
	if exists(filepath.Join(home, "cyfr-browser")) || log.Len() != 0 {
		t.Fatalf("the fetched Chrome's folder is still there, or a removal was said: %q", log.String())
	}
	for _, path := range []string{"chrome/Default/Sessions/Session_1", "tmp/kept", "cyfr-browser-notes"} {
		if !exists(filepath.Join(home, path)) {
			t.Errorf("%s was removed", path)
		}
	}
}

// A symlink in a listed path's place is removed as a link: what it points
// at is never followed, and stays.
func TestALeftoverThatIsALinkIsNotFollowed(t *testing.T) {
	home, elsewhere := t.TempDir(), t.TempDir()
	write(t, filepath.Join(elsewhere, "versions/131.0.6778.85/chrome"), "not the home's")
	if err := os.Symlink(elsewhere, filepath.Join(home, "cyfr-browser")); err != nil {
		t.Fatal(err)
	}
	var log bytes.Buffer
	removeLeftovers(home, &log)
	if exists(filepath.Join(home, "cyfr-browser")) || log.Len() != 0 {
		t.Fatalf("the link is still there, or a removal was said: %q", log.String())
	}
	if !exists(filepath.Join(elsewhere, "versions/131.0.6778.85/chrome")) {
		t.Fatal("what the link pointed at was removed")
	}
}

// A home holding none of them is left as it is, and nothing is said; a
// removal that fails is said once and leaves the browser to start.
func TestAHomeWithNoLeftoversIsLeftAlone(t *testing.T) {
	home := t.TempDir()
	write(t, filepath.Join(home, "chrome/Default/Preferences"), "{}")
	var log bytes.Buffer
	removeLeftovers(home, &log)
	if log.Len() != 0 || !exists(filepath.Join(home, "chrome/Default/Preferences")) {
		t.Fatalf("a home with nothing to remove was changed or said %q", log.String())
	}
	locked := t.TempDir()
	write(t, filepath.Join(locked, "cyfr-browser/checked"), "fetched")
	if err := os.Chmod(filepath.Join(locked, "cyfr-browser"), 0o500); err != nil {
		t.Fatal(err)
	}
	defer os.Chmod(filepath.Join(locked, "cyfr-browser"), 0o700)
	if os.Geteuid() == 0 {
		t.Skip("root removes from a read-only folder")
	}
	removeLeftovers(locked, &log)
	if bytes.Count(log.Bytes(), []byte("\n")) != 1 || !exists(filepath.Join(locked, "cyfr-browser/checked")) {
		t.Fatalf("a removal that failed was said %q", log.String())
	}
}
