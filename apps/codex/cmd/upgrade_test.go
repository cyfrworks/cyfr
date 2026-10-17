// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/cyfr/codex/internal/release"
	"github.com/cyfr/codex/internal/version"
)

// upgradeScenario is `cyfr upgrade` from the current release against a
// latest one, its binary a file of its own, every release lookup and the
// download substituted, and a curl and an sh on PATH that record any run.
type upgradeScenario struct {
	t       *testing.T
	self    string
	ran     string
	fetched []string
	answer  func() ([]byte, error)
}

func newUpgradeScenario(t *testing.T, current, latest string) *upgradeScenario {
	dir := t.TempDir()
	s := &upgradeScenario{t: t, self: filepath.Join(dir, "cyfr"), ran: filepath.Join(t.TempDir(), "ran")}
	// Chmod sets the mode apart from the umask, so the install is seen to
	// keep it.
	if err := errors.Join(os.WriteFile(s.self, []byte("old cyfr"), 0755), os.Chmod(s.self, 0755)); err != nil {
		t.Fatal(err)
	}
	bin := t.TempDir()
	for _, name := range []string{"curl", "sh"} {
		if err := os.WriteFile(filepath.Join(bin, name), []byte("#!/bin/sh\necho \"$0 $*\" >> "+s.ran+"\n"), 0755); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("PATH", bin)
	savedVersion, savedLatest, savedFetch, savedCask, savedSelf := version.Version, latestRelease, fetchBinary, caskInstalled, selfExecutable
	t.Cleanup(func() {
		version.Version, latestRelease, fetchBinary, caskInstalled, selfExecutable = savedVersion, savedLatest, savedFetch, savedCask, savedSelf
	})
	version.Version = current
	latestRelease = func(context.Context) (string, error) { return latest, nil }
	caskInstalled = func() bool { return false }
	selfExecutable = func() (string, error) { return s.self, nil }
	s.answer = func() ([]byte, error) { return []byte("new cyfr " + latest), nil }
	fetchBinary = func(_ context.Context, v, goos, goarch string) ([]byte, error) {
		s.fetched = append(s.fetched, v)
		return s.answer()
	}
	return s
}

func (s *upgradeScenario) run() (string, error) {
	var out bytes.Buffer
	err := runUpgrade(context.Background(), &out)
	return out.String(), err
}

// unchanged fails unless the binary is the old one and nothing else lies
// in its directory: no temporary file is left behind.
func (s *upgradeScenario) unchanged() {
	s.t.Helper()
	if got := read(s.t, s.self); got != "old cyfr" {
		s.t.Errorf("the binary holds %q, want the old one", got)
	}
	s.alone()
}

func (s *upgradeScenario) alone() {
	s.t.Helper()
	if got := read(s.t, s.ran); got != "<absent>" {
		s.t.Errorf("cyfr upgrade ran %q", got)
	}
	entries, _ := os.ReadDir(filepath.Dir(s.self))
	if len(entries) != 1 {
		var names []string
		for _, e := range entries {
			names = append(names, e.Name())
		}
		s.t.Errorf("the binary's directory holds %v", names)
	}
}

// Only a release IsNewer says is newer is installed: an equal one, an
// older line's later patch and a development build install nothing, and
// versions compare numerically.
func TestUpgradeInstallsOnlyANewerRelease(t *testing.T) {
	for _, c := range []struct {
		current, latest string
		installs        bool
		says            string
	}{
		{"0.9.0", "0.9.0", false, "already up to date"},
		{"0.9.1", "0.8.7", false, "not older than the latest release 0.8.7"},
		{"dev", "0.9.0", false, "not older than the latest release"},
		{"0.9.0", "0.10.0", true, "upgraded to 0.10.0"},
		{"v0.9.0", "0.9.1", true, "upgraded to 0.9.1"},
	} {
		t.Run(c.current+" to "+c.latest, func(t *testing.T) {
			s := newUpgradeScenario(t, c.current, c.latest)
			out, err := s.run()
			if err != nil || !strings.Contains(out, c.says) {
				t.Fatalf("cyfr upgrade answered %v:\n%s", err, out)
			}
			if !c.installs {
				if len(s.fetched) != 0 {
					t.Errorf("cyfr upgrade fetched %v", s.fetched)
				}
				s.unchanged()
				return
			}
			if !slices.Equal(s.fetched, []string{c.latest}) {
				t.Errorf("cyfr upgrade fetched %v, want %s", s.fetched, c.latest)
			}
			if got := read(t, s.self); got != "new cyfr "+c.latest {
				t.Errorf("the binary holds %q, want the release's", got)
			}
			if info, err := os.Stat(s.self); err != nil || info.Mode().Perm() != 0755 {
				t.Errorf("the binary's mode is %v (error %v), want 0755", info.Mode().Perm(), err)
			}
			s.alone()
		})
	}
}

// A release that does not verify, or does not download, leaves the binary
// as it was; no installer runs.
func TestUpgradeRefusesWhatDoesNotVerify(t *testing.T) {
	for name, c := range map[string]struct {
		err  error
		says string
	}{
		"unverified": {fmt.Errorf("%w: cyfr_0.9.1_linux_amd64.tar.gz does not match the release's signed checksums.txt", release.ErrUnverified), "did not verify"},
		"transport":  {errors.New("download https://github.com/x: HTTP 503"), "could not download release 0.9.1"},
	} {
		t.Run(name, func(t *testing.T) {
			s := newUpgradeScenario(t, "0.9.0", "0.9.1")
			s.answer = func() ([]byte, error) { return nil, c.err }
			out, err := s.run()
			if err == nil || !strings.Contains(err.Error(), c.says) || !strings.Contains(err.Error(), s.self+" is unchanged") {
				t.Fatalf("cyfr upgrade answered %v:\n%s", err, out)
			}
			s.unchanged()
		})
	}

	// A directory that is not writable keeps the binary as it was.
	s := newUpgradeScenario(t, "0.9.0", "0.9.1")
	if os.Geteuid() == 0 {
		t.Skip("root writes any directory")
	}
	if err := os.Chmod(filepath.Dir(s.self), 0555); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chmod(filepath.Dir(s.self), 0755) })
	if out, err := s.run(); err == nil || !strings.Contains(err.Error(), "could not be installed") || !strings.Contains(err.Error(), "unchanged") {
		t.Fatalf("cyfr upgrade answered %v:\n%s", err, out)
	}
	s.unchanged()
}
