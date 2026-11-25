// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build windows

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
	"strconv"
	"strings"

	"github.com/cyfr/codex/internal/release"
)

// systemAppRoad is Windows': Windows Installer installs the release's
// verified MSI for this account, its own transaction undoing an install
// that fails.
func systemAppRoad() appRoad { return msiRoad{} }

// msiRoad updates the per-account MSI. Windows Installer ends the
// processes of a terminal in which a file it replaces runs, whatever its
// Restart Manager is told, so the cyfr inside the app that runs this
// update is renamed aside first (a running program may be renamed, never
// replaced), which leaves the installer no file of its in use; the one
// renamed aside is removed by a later update once nothing runs it, and is
// renamed back where the installer put no cyfr in its place. The MSI's
// version is its release's MAJOR.MINOR.PATCH, so consecutive
// pre-releases of one release install over each other, and Windows
// Installer refuses a release whose MAJOR.MINOR.PATCH is older than the
// installed one's: that refusal is made before anything closes.
type msiRoad struct{}

// msiexecProgram is Windows Installer's program, a variable so tests stand
// in for it.
var msiexecProgram = "msiexec"

// msiAside is the suffix of the app's cyfr renamed aside, before the id of
// the process that ran it.
const msiAside = ".old-"

func (msiRoad) fetch(ctx context.Context, out io.Writer, before, target string) (*staged, error) {
	if core := func(v string) string { c, _, _ := strings.Cut(v, "-"); return c }; release.IsVersion(before) && release.IsNewer(core(before), core(target)) {
		return nil, fmt.Errorf("Windows Installer does not install release %s over the newer %s; nothing was changed and CYFR runs as it did. To run release %s, remove CYFR in Windows' Settings, Apps, Installed apps, then install release %s from %s/tag/%s", target, before, target, target, releasesPage, target)
	}
	return fetchInstaller(ctx, out, target, "windows", runtime.GOARCH)
}

// elevate takes nothing: the MSI installs for this account alone.
func (msiRoad) elevate(io.Writer, string, bool) (func(), error) { return func() {}, nil }

func (msiRoad) replace(out io.Writer, s *staged, _ bool) error {
	carried, err := appCyfr()
	if err != nil {
		return fmt.Errorf("cyfr update could not tell where the app's cyfr is (%v); nothing was replaced", err)
	}
	removeAsides(carried)
	if self, err := selfExecutable(); err == nil && samePath(self, carried) {
		aside := carried + msiAside + strconv.Itoa(os.Getpid())
		if err := os.Rename(carried, aside); err != nil {
			return fmt.Errorf("this cyfr could not step aside for the installer (%v); nothing was replaced", err)
		}
		s.kept = aside
	}
	fmt.Fprintln(out, "Installing the CYFR app with Windows Installer...")
	log := filepath.Join(s.dir, "msiexec.log")
	err = runWithin(appReplaceWithin, exec.Command(msiexecProgram, "/i", s.file, "/qn", "/norestart", "/l*v", log))
	var exit *exec.ExitError
	switch {
	case errors.As(err, &exit) && exit.ExitCode() == msiRebootNeeded:
		return nil
	case errors.As(err, &exit):
		return fmt.Errorf("Windows Installer could not install the CYFR app (exit status %d%s)", exit.ExitCode(), msiSays(exit.ExitCode()))
	case err != nil:
		return fmt.Errorf("Windows Installer could not install the CYFR app (%w)", err)
	}
	return nil
}

// finish puts the cyfr set aside back over whatever is at its place where
// the installer failed or the installed app's cyfr does not answer the
// release, so the cyfr the person runs is the one that ran this; once the
// release is confirmed it stays aside, removed by a later update.
func (msiRoad) finish(_ io.Writer, s *staged, confirmed bool) error {
	if confirmed || s.kept == "" {
		return nil
	}
	carried := strings.TrimSuffix(s.kept, s.kept[strings.LastIndex(s.kept, msiAside):])
	if err := os.Remove(carried); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return fmt.Errorf("the new app's cyfr could not be taken away from %s: %w", carried, err)
	}
	if err := os.Rename(s.kept, carried); err != nil {
		return fmt.Errorf("the cyfr set aside could not go back to %s: %w", carried, err)
	}
	s.kept = ""
	return nil
}

func (msiRoad) closesTheBox() ([]string, []string) { return nil, nil }

// msiRebootNeeded is Windows Installer's status for an install that is
// done and wants a restart to finish removing what it replaced; whether
// the app is the release, its own cyfr answers.
const msiRebootNeeded = 3010

// msiSays is what a Windows Installer status means to a person, for the
// statuses an update meets.
func msiSays(status int) string {
	switch status {
	case 1602:
		return ": the install was cancelled"
	case 1603:
		return ": the install failed and was undone"
	case 1618:
		return ": another install is running; run cyfr update again once it ends"
	case 1625:
		return ": this computer's policy forbids the install"
	}
	return ""
}

// removeAsides removes the app's cyfr an earlier update renamed aside,
// where nothing runs it any longer; one still running stays.
func removeAsides(carried string) {
	asides, _ := filepath.Glob(carried + msiAside + "*")
	for _, a := range asides {
		_ = os.Remove(a)
	}
}
