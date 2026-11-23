// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"golang.org/x/sys/unix"
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

// terminal opens a pseudo-terminal pair, as the backends service gives the
// driver one: its controller and the terminal the driver runs on.
func terminal(t *testing.T) (*os.File, *os.File) {
	t.Helper()
	controller, err := os.OpenFile("/dev/ptmx", os.O_RDWR|unix.O_NOCTTY, 0)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { controller.Close() })
	if err := unix.IoctlSetPointerInt(int(controller.Fd()), unix.TIOCSPTLCK, 0); err != nil {
		t.Fatal(err)
	}
	n, err := unix.IoctlGetInt(int(controller.Fd()), unix.TIOCGPTN)
	if err != nil {
		t.Fatal(err)
	}
	tty, err := os.OpenFile(fmt.Sprintf("/dev/pts/%d", n), os.O_RDWR|unix.O_NOCTTY, 0)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { tty.Close() })
	return controller, tty
}

// A driver whose HOME names no folder by an absolute path removes nothing:
// it says hello with the error and exits 1, and a cyfr-browser in the
// folder it runs in, which a relative home would resolve the leftover's
// name against, is left as it was.
func TestAHomeThatNamesNoFolderRemovesNothing(t *testing.T) {
	for name, home := range map[string]string{"unset": "", "relative": "home", "a file": "file"} {
		t.Run(name, func(t *testing.T) {
			dir := t.TempDir()
			t.Chdir(dir)
			write(t, filepath.Join(dir, "cyfr-browser", "versions", "keep"), "the folder's own")
			write(t, filepath.Join(dir, "file"), "a file")
			if home == "file" {
				home = filepath.Join(dir, "file")
			}
			t.Setenv("HOME", home)
			controller, tty := terminal(t)
			stdin, stdout := os.Stdin, os.Stdout
			os.Stdin, os.Stdout = tty, tty
			code := run(nil)
			os.Stdin, os.Stdout = stdin, stdout
			if code != 1 {
				t.Fatalf("the driver exited %d, not 1", code)
			}
			if !exists(filepath.Join(dir, "cyfr-browser", "versions", "keep")) {
				t.Fatal("the driver removed the folder's cyfr-browser")
			}
			said := make([]byte, 4096)
			n, err := controller.Read(said)
			if err != nil {
				t.Fatal(err)
			}
			if !bytes.Contains(said[:n], []byte(`"error":"The browser could not start: HOME names no folder."`)) {
				t.Fatalf("the driver said %q", said[:n])
			}
		})
	}
}
