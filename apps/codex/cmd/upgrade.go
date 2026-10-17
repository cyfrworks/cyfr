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
	"github.com/spf13/cobra"
)

func init() {
	rootCmd.AddCommand(upgradeCmd)
}

var upgradeCmd = &cobra.Command{
	Use:     "upgrade",
	Short:   "Upgrade the CYFR Codex binary",
	Long:    "Upgrade the CYFR Codex binary (system-wide) to the newest release, when it is newer than this one. A Homebrew cask install upgrades through brew; any other install downloads the release's archive for this platform, verifies it against the release's checksums.txt signed by the release workflow for that tag, and only then replaces this binary in place. Run 'cyfr update' in each project directory to pull the latest Docker image and update scaffold files.",
	GroupID: "server",
	RunE: func(cmd *cobra.Command, args []string) error {
		return runUpgrade(cmd.Context(), cmd.OutOrStdout())
	},
}

// The release lookups and the install, each a package variable so tests
// substitute them.
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
	selfExecutable = os.Executable
)

// fetchBinaryTimeout bounds the archive's download and verification.
const fetchBinaryTimeout = 10 * time.Minute

const updateReminder = "Run 'cyfr update' in each project directory to pull the latest Docker images and update scaffold files."

// runUpgrade is `cyfr upgrade`. A release is installed only when
// release.IsNewer says it is newer than this one, so an older line's later
// patch never downgrades the CLI and a development build is never
// replaced. Outside Homebrew, nothing is written before the archive
// verifies, and the binary is replaced by a rename, so a failure leaves
// the running one in place.
func runUpgrade(ctx context.Context, out io.Writer) error {
	if ctx == nil {
		ctx = context.Background()
	}
	lookup, cancel := context.WithTimeout(ctx, 30*time.Second)
	latest, err := latestRelease(lookup)
	cancel()
	if err != nil {
		return fmt.Errorf("Failed to check for updates: %w", err)
	}

	current := strings.TrimPrefix(version.Version, "v")
	switch {
	case current == latest:
		fmt.Fprintf(out, "CYFR Codex already up to date (%s)\n", current)
		fmt.Fprintln(out, "\n"+updateReminder)
		return nil
	case !release.IsNewer(latest, current):
		fmt.Fprintf(out, "CYFR Codex %s is not older than the latest release %s; nothing was upgraded.\n", current, latest)
		return nil
	}
	fmt.Fprintf(out, "Upgrading CYFR Codex from %s to %s...\n", current, latest)

	if caskInstalled() {
		return upgradeCask(out, latest)
	}

	self, err := selfExecutable()
	if err == nil {
		self, err = filepath.EvalSymlinks(self)
	}
	if err != nil {
		return fmt.Errorf("cyfr upgrade could not find its own binary (%v); nothing was upgraded", err)
	}
	fmt.Fprintf(out, "Downloading and verifying release %s for %s/%s...\n", latest, runtime.GOOS, runtime.GOARCH)
	fetch, cancel := context.WithTimeout(ctx, fetchBinaryTimeout)
	binary, err := fetchBinary(fetch, latest, runtime.GOOS, runtime.GOARCH)
	cancel()
	switch {
	case errors.Is(err, release.ErrUnverified):
		return fmt.Errorf("Release %s did not verify (%v); %s is unchanged", latest, err, self)
	case err != nil:
		return fmt.Errorf("cyfr upgrade could not download release %s (%v); %s is unchanged. Download it from https://github.com/cyfrworks/cyfr/releases/tag/%s", latest, err, self, latest)
	}
	if err := replaceExecutable(self, binary); err != nil {
		return fmt.Errorf("Release %s verified but could not be installed at %s (%v); the binary there is unchanged. Run 'sudo cyfr upgrade' if its directory is not yours to write", latest, self, err)
	}
	fmt.Fprintf(out, "CYFR Codex upgraded to %s (%s)\n", latest, self)
	fmt.Fprintln(out, "\n"+updateReminder)
	return nil
}

// upgradeCask upgrades a Homebrew cask install and checks the version brew
// installed.
func upgradeCask(out io.Writer, latest string) error {
	update := exec.Command("brew", "update")
	update.Stdout = out
	update.Stderr = os.Stderr
	if err := update.Run(); err != nil {
		return fmt.Errorf("brew update failed: %w", err)
	}

	upgrade := exec.Command("brew", "upgrade", "--cask", "cyfr")
	upgrade.Stdout = out
	upgrade.Stderr = os.Stderr
	upgradeErr := upgrade.Run()

	// Homebrew can exit successfully without changing the installed version.
	// Verify the installed version before reporting an upgrade.
	switch installed := installedCaskVersion(); {
	case upgradeErr != nil:
		fmt.Fprintf(out, "Warning: brew upgrade --cask cyfr: %v\n", upgradeErr)
	case installed == latest:
		fmt.Fprintf(out, "CYFR Codex upgraded to %s\n", latest)
	case installed != "":
		fmt.Fprintf(out, "Warning: brew exited cleanly but cyfr is still %s (expected %s).\n", installed, latest)
		fmt.Fprintln(out, "  Try `brew update-reset` then `cyfr upgrade` again, or reinstall with `brew uninstall --cask cyfr && brew install --cask cyfr`.")
	default:
		fmt.Fprintln(out, "Warning: could not verify the installed cyfr version; check with `brew list --cask --versions cyfr`.")
	}
	fmt.Fprintln(out, "\n"+updateReminder)
	return nil
}

// replaceExecutable writes binary beside self, synced and with self's
// mode, and renames it over self, so self is the old binary or the new one
// whole; renaming over a running binary is allowed where writing into it is
// not. Windows cannot rename over a running executable, so there the old
// one is renamed aside first and back again if the new one does not land.
func replaceExecutable(self string, binary []byte) error {
	mode := os.FileMode(0755)
	if info, err := os.Stat(self); err == nil {
		mode = info.Mode().Perm() | 0100
	}
	tmp, err := os.CreateTemp(filepath.Dir(self), "."+filepath.Base(self)+".upgrade-*")
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
// (e.g. "0.5.2"), or "" if it can't be determined. `brew list --cask --versions
// cyfr` prints a line like "cyfr 0.5.2".
func installedCaskVersion() string {
	out, err := exec.Command("brew", "list", "--cask", "--versions", "cyfr").Output()
	if err != nil {
		return ""
	}
	fields := strings.Fields(strings.TrimSpace(string(out)))
	if len(fields) < 2 {
		return ""
	}
	return strings.TrimPrefix(fields[len(fields)-1], "v")
}
