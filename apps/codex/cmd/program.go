// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/cyfr/codex/internal/release"
	"github.com/cyfr/codex/internal/version"
)

// The release lookups, the install and the handover, each a package
// variable so tests substitute them.
var (
	latestRelease = release.Latest
	fetchBinary   = release.FetchBinary
	caskInstalled = func() bool {
		if _, err := exec.LookPath("brew"); err != nil {
			return false
		}
		// --cask avoids the same-name formula->cask ambiguity.
		return exec.Command("brew", "list", "--cask", "cyfr").Run() == nil
	}
	// caskBinary is the cyfr a Homebrew cask install links into the
	// prefix's bin, which outlives the version directory brew upgrades.
	caskBinary = func() (string, error) {
		out, err := exec.Command("brew", "--prefix").Output()
		if err != nil {
			return "", fmt.Errorf("brew --prefix: %w", err)
		}
		return filepath.Join(strings.TrimSpace(string(out)), "bin", release.BinaryName(runtime.GOOS)), nil
	}
	selfExecutable = os.Executable
	// handOver runs the rest of `cyfr update` as the program at path
	// (continueAs, by platform).
	handOver = continueAs
)

// fetchBinaryTimeout bounds the archive's download and verification.
const fetchBinaryTimeout = 10 * time.Minute

// releasesPage lists every published release, pre-releases included.
const releasesPage = "https://github.com/cyfrworks/cyfr/releases"

// updateOptions are `cyfr update`'s flags.
type updateOptions struct {
	// version is the exact release to install (--version); empty is the
	// newest release that is not a pre-release.
	version string
	// yes updates the home without asking (--yes).
	yes bool
	// continueAs is the release the program step installed and handed
	// over to (--continue-as): the new program skips the program step.
	continueAs string
	// noInteractive is the global --no-interactive, passed on at the
	// handover.
	noInteractive bool
}

// handedOver is the status of the new program the program step ran to
// finish `cyfr update` as a child, where a running program cannot be
// replaced by exec (Windows); the child printed its own outcome.
type handedOver struct{ status int }

func (h handedOver) Error() string {
	return fmt.Sprintf("the updated cyfr exited with status %d", h.status)
}

// updateProgram is `cyfr update`'s program step: it installs the target
// release when it is to be installed, then hands the rest of the update
// over to the new program, answering finished once that program has run
// it (a child, on Windows); on Unix a handover that succeeds never
// returns. The target is --version's exact release, older or a
// pre-release included, else release.Latest's, installed only when
// release.IsNewer says it is newer than this one, so a plain update never
// moves to a pre-release, an older line's later patch never downgrades and
// a development build is never replaced. Outside Homebrew nothing is
// written before the archive verifies, and the program is replaced by a
// rename, so a failure leaves the running one in place.
func updateProgram(ctx context.Context, out io.Writer, o updateOptions) (bool, error) {
	current := version.Version
	if o.version != "" && !release.IsVersion(o.version) {
		return false, fmt.Errorf("--version %q is not a release version (MAJOR.MINOR.PATCH, or with a pre-release, such as 0.6.0 or 0.6.0-alpha.1); nothing was changed", o.version)
	}
	target := o.version
	if target == "" {
		if !release.IsVersion(current) {
			fmt.Fprintf(out, "This cyfr is a development build (%s), which cyfr update does not replace.\n", current)
			return false, nil
		}
		lookup, cancel := context.WithTimeout(ctx, 30*time.Second)
		latest, err := latestRelease(lookup)
		cancel()
		switch {
		case errors.Is(err, release.ErrNoRelease):
			fmt.Fprintf(out, "No release of CYFR is published yet apart from pre-releases, so this cyfr (%s) stays; name one with 'cyfr update --version <version>' (%s lists them).\n", current, releasesPage)
			return false, nil
		case err != nil:
			return false, fmt.Errorf("cyfr update could not look up the newest release (%v); nothing was changed", err)
		case latest == current:
			fmt.Fprintf(out, "cyfr %s is the newest release.\n", current)
			return false, nil
		case !release.IsNewer(latest, current):
			fmt.Fprintf(out, "cyfr %s is newer than the newest release, %s, so it stays.\n", current, latest)
			return false, nil
		}
		target = latest
	} else if target == current {
		fmt.Fprintf(out, "This cyfr is release %s already.\n", current)
		return false, nil
	}
	if release.IsNewer(current, target) {
		fmt.Fprintf(out, "Installing cyfr %s, older than this cyfr's %s, as --version asks...\n", target, current)
	} else {
		fmt.Fprintf(out, "Updating cyfr from %s to %s...\n", current, target)
	}

	var path string
	if caskInstalled() {
		p, err := updateCask(ctx, out, target, o.version != "")
		if err != nil {
			return false, err
		}
		path = p
	} else {
		p, err := replaceSelf(ctx, out, target)
		if err != nil {
			return false, err
		}
		path = p
	}
	if ctx.Err() != nil {
		return false, fmt.Errorf("cyfr update was interrupted once cyfr %s was installed, before the home step; run 'cyfr update' again to update the home", target)
	}

	args := []string{path, "update", "--continue-as", target}
	if o.yes {
		args = append(args, "--yes")
	}
	if o.noInteractive {
		args = append(args, "--no-interactive")
	}
	status, err := handOver(path, args)
	switch {
	case err != nil:
		return false, fmt.Errorf("cyfr %s is installed at %s, but it could not be started (%v); the home was not touched. Run 'cyfr update' again", target, path, err)
	case status != 0:
		return false, handedOver{status}
	}
	return true, nil
}

// replaceSelf downloads and verifies release target's binary for this
// platform and installs it over this program's file, answering the file's
// path with its links resolved.
func replaceSelf(ctx context.Context, out io.Writer, target string) (string, error) {
	self, err := selfExecutable()
	if err == nil {
		self, err = filepath.EvalSymlinks(self)
	}
	if err != nil {
		return "", fmt.Errorf("cyfr update could not find its own program file (%v); nothing was changed", err)
	}
	fmt.Fprintf(out, "Downloading and verifying release %s for %s/%s...\n", target, runtime.GOOS, runtime.GOARCH)
	fetch, cancel := context.WithTimeout(ctx, fetchBinaryTimeout)
	binary, err := fetchBinary(fetch, target, runtime.GOOS, runtime.GOARCH)
	cancel()
	switch {
	case errors.Is(err, release.ErrUnverified):
		return "", fmt.Errorf("Release %s did not verify (%v); %s is unchanged and the home was not touched", target, err, self)
	case err != nil:
		return "", fmt.Errorf("cyfr update could not download release %s (%v); %s is unchanged and the home was not touched. Download it from %s/tag/%s", target, err, self, releasesPage, target)
	}
	if err := replaceExecutable(self, binary); err != nil {
		return "", fmt.Errorf("Release %s verified but could not be installed at %s (%v); the program there is unchanged and the home was not touched. Run 'sudo cyfr update' if its directory is not yours to write", target, self, err)
	}
	fmt.Fprintf(out, "cyfr %s is installed at %s.\n", target, self)
	return self, nil
}

// updateCask updates a Homebrew cask install, which installs only the
// release its tap names: the newest release that is not a pre-release.
// A --version naming another release is refused, pointing at the install
// script, which installs any release. The version brew installed is
// checked before the new program is handed the update.
func updateCask(ctx context.Context, out io.Writer, target string, exact bool) (string, error) {
	if exact {
		lookup, cancel := context.WithTimeout(ctx, 30*time.Second)
		latest, err := latestRelease(lookup)
		cancel()
		if err != nil || latest != target {
			return "", fmt.Errorf("This cyfr was installed by Homebrew, which installs only the release its tap names, the newest one that is not a pre-release; nothing was changed. To run release %s, install it with the install script: curl -fsSL https://raw.githubusercontent.com/cyfrworks/cyfr/main/scripts/install.sh | CYFR_VERSION=%s sh", target, target)
		}
	}
	// brew runs to its end: it shares the terminal's process group, so an
	// interrupt reaches it as it reaches cyfr, and brew answers it itself.
	for _, args := range [][]string{{"update"}, {"upgrade", "--cask", "cyfr"}} {
		c := exec.Command("brew", args...)
		c.Stdout, c.Stderr = out, os.Stderr
		if err := c.Run(); err != nil {
			return "", fmt.Errorf("brew %s failed (%v); the home was not touched", strings.Join(args, " "), err)
		}
	}
	// Homebrew can exit successfully without changing the installed version.
	switch installed := installedCaskVersion(); {
	case installed == "":
		return "", errors.New("brew upgraded the cyfr cask, but its version could not be read (brew list --cask --versions cyfr); the home was not touched. Run 'cyfr update' again")
	case installed != target:
		return "", fmt.Errorf("brew exited cleanly but the cyfr cask is still %s, not %s; the home was not touched. Try 'brew update-reset' and 'cyfr update' again, or reinstall with 'brew uninstall --cask cyfr && brew install --cask cyfr'", installed, target)
	}
	path, err := caskBinary()
	if err != nil {
		return "", fmt.Errorf("brew installed cyfr %s, but cyfr update could not find it (%v); the home was not touched. Run 'cyfr update' again", target, err)
	}
	fmt.Fprintf(out, "cyfr %s is installed by Homebrew at %s.\n", target, path)
	return path, nil
}

// replaceExecutable writes binary beside self, synced and with self's
// mode, and renames it over self, so self is the old binary or the new one
// whole; renaming over a running binary is allowed where writing into it is
// not. Windows cannot rename over a running executable, so there the old
// one is renamed aside first and back again if the new one does not land;
// the one set aside is removed by the next install.
func replaceExecutable(self string, binary []byte) error {
	mode := os.FileMode(0755)
	if info, err := os.Stat(self); err == nil {
		mode = info.Mode().Perm() | 0100
	}
	tmp, err := os.CreateTemp(filepath.Dir(self), "."+filepath.Base(self)+".update-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	_, err = tmp.Write(binary)
	if err = errors.Join(err, tmp.Chmod(mode), tmp.Sync(), tmp.Close()); err != nil {
		return err
	}
	if runtime.GOOS != "windows" {
		return os.Rename(tmp.Name(), self)
	}
	aside := self + ".old"
	os.Remove(aside)
	if err := os.Rename(self, aside); err != nil {
		return err
	}
	if err := os.Rename(tmp.Name(), self); err != nil {
		return errors.Join(err, os.Rename(aside, self))
	}
	return nil
}

// installedCaskVersion returns the version Homebrew reports for the cyfr cask
// (e.g. "0.6.0"), or "" if it can't be determined. `brew list --cask
// --versions cyfr` prints a line like "cyfr 0.6.0".
func installedCaskVersion() string {
	out, err := exec.Command("brew", "list", "--cask", "--versions", "cyfr").Output()
	if err != nil {
		return ""
	}
	fields := strings.Fields(strings.TrimSpace(string(out)))
	if len(fields) < 2 {
		return ""
	}
	return fields[len(fields)-1]
}
