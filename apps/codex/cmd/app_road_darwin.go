// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build darwin

package cmd

import (
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"golang.org/x/sys/unix"
)

// systemAppRoad is macOS's for an app installed from its DMG: the whole
// signed app from the release's verified DMG replaces the one in
// /Applications. A Homebrew cask install takes caskRoad instead.
func systemAppRoad() appRoad { return macRoad{apps: filepath.Dir(installedAppBundle)} }

// macRoad replaces CYFR.app in apps whole. The new app is copied from the
// verified DMG into a hidden bundle beside it, macStaging, its signature
// checked and its team the installed app's; then one rename swaps the two
// (RENAME_SWAP), so apps holds the old app or the new one whole at every
// instant. The new app's own cyfr must answer the release, or the swap is
// made again, back; only then is the old app, now in macStaging, removed.
// A crash between the swap and that removal leaves the new app installed
// and the old one hidden in macStaging, which the next update removes
// before it stages anything; so does a crash while the new app is copied.
type macRoad struct{ apps string }

// macStaging is the hidden bundle beside CYFR.app a replacement stages in.
const macStaging = ".CYFR-update.app"

// The bounds of the Mac road's steps: mounting and leaving the DMG, the
// copy of its app, the check of the app's signature.
const (
	hdiutilWithin  = 2 * time.Minute
	dittoWithin    = 10 * time.Minute
	codesignWithin = 2 * time.Minute
)

func (macRoad) fetch(ctx context.Context, out io.Writer, _, target string) (*staged, error) {
	return fetchInstaller(ctx, out, target, "darwin", runtime.GOARCH)
}

// elevate takes nothing, and refuses where this account may not replace
// the app: apps and every folder of the installed app must be its to
// write, or the old app could not be swapped and removed whole.
func (r macRoad) elevate(_ io.Writer, again string) (func(), error) {
	bundle := filepath.Join(r.apps, "CYFR.app")
	unwritable := ""
	if unix.Access(r.apps, unix.W_OK) != nil {
		unwritable = r.apps
	}
	_ = filepath.WalkDir(bundle, func(path string, d fs.DirEntry, err error) error {
		if unwritable != "" {
			return filepath.SkipAll
		}
		if err != nil || (d.IsDir() && unix.Access(path, unix.W_OK) != nil) {
			unwritable = path
			return filepath.SkipAll
		}
		return nil
	})
	if unwritable != "" {
		return nil, fmt.Errorf("This account may not write %s, so the CYFR app cannot be replaced; nothing was changed and CYFR runs as it did. Run 'sudo %s'", unwritable, again)
	}
	return func() {}, nil
}

func (r macRoad) replace(out io.Writer, s *staged, _ bool) error {
	installed := filepath.Join(r.apps, "CYFR.app")
	staging := filepath.Join(r.apps, macStaging)
	// What a crash left of an update before this one.
	if err := os.RemoveAll(staging); err != nil {
		return fmt.Errorf("an earlier update's %s could not be removed (%v); nothing was replaced", staging, err)
	}
	mount := filepath.Join(s.dir, "mount")
	if err := os.Mkdir(mount, 0o700); err != nil {
		return err
	}
	fmt.Fprintln(out, "Copying the new CYFR app from its disk image...")
	if err := runWithin(hdiutilWithin, exec.Command("hdiutil", "attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount, s.file)); err != nil {
		return fmt.Errorf("the disk image could not be opened (%w); nothing was replaced", err)
	}
	copied := runWithin(dittoWithin, exec.Command("ditto", filepath.Join(mount, "CYFR.app"), staging))
	_ = runWithin(hdiutilWithin, exec.Command("hdiutil", "detach", "-force", mount))
	if copied != nil {
		_ = os.RemoveAll(staging)
		return fmt.Errorf("the new app could not be copied out of its disk image (%w); nothing was replaced", copied)
	}
	if err := sameSigner(staging, installed); err != nil {
		_ = os.RemoveAll(staging)
		return fmt.Errorf("the new app's signature was refused (%w); nothing was replaced", err)
	}
	if err := unix.RenamexNp(staging, installed, unix.RENAME_SWAP); err != nil {
		_ = os.RemoveAll(staging)
		return fmt.Errorf("the new app could not take the old one's place (%w); nothing was replaced", err)
	}
	if got := machine.appRelease(); got != s.target {
		if err := unix.RenamexNp(staging, installed, unix.RENAME_SWAP); err != nil {
			return fmt.Errorf("the new app answers %q, not %s, and the old one could not be put back (%w); it is %s", got, s.target, err, staging)
		}
		_ = os.RemoveAll(staging)
		return fmt.Errorf("the new app's own cyfr answered %q, not %s, so the app before it was put back", got, s.target)
	}
	if err := os.RemoveAll(staging); err != nil {
		fmt.Fprintf(out, "The CYFR app before this one could not be removed from %s (%v); the next update removes it.\n", staging, err)
	}
	return nil
}

func (macRoad) closesTheBox() ([]string, []string) { return nil, nil }

// sameSigner checks the app at path: its signature verifies, strictly and
// to its nested code, and its team is the installed app's, so an update
// never moves the app, and with it the keychain items its team holds, to
// another signer.
func sameSigner(path, installed string) error {
	verify := exec.Command("codesign", "--verify", "--strict", "--deep", path)
	var said strings.Builder
	verify.Stderr = &said
	if err := runWithin(codesignWithin, verify); err != nil {
		return fmt.Errorf("codesign --verify: %v: %s", err, strings.TrimSpace(said.String()))
	}
	want, err := teamOf(installed)
	if err != nil {
		return err
	}
	got, err := teamOf(path)
	if err != nil {
		return err
	}
	if got != want {
		return fmt.Errorf("it is signed by the team %q, the installed app by %q", got, want)
	}
	return nil
}

// teamOf is the team codesign names for the app at path, "not set" for an
// app signed by no team.
func teamOf(path string) (string, error) {
	c := exec.Command("codesign", "-d", "--verbose=2", path)
	var said strings.Builder
	c.Stderr = &said
	if err := runWithin(codesignWithin, c); err != nil {
		return "", fmt.Errorf("codesign -d %s: %v", path, err)
	}
	for _, line := range strings.Split(said.String(), "\n") {
		if team, ok := strings.CutPrefix(line, "TeamIdentifier="); ok {
			return strings.TrimSpace(team), nil
		}
	}
	return "", errors.New("codesign named no team for " + path)
}
