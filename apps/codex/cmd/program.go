// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"context"
	"encoding/json"
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
		if brewProgram() == "" {
			return false
		}
		// --cask avoids the same-name formula->cask ambiguity.
		return runWithin(brewReadWithin, brewCommand("list", "--cask", "cyfr")) == nil
	}
	// caskBinary is the cyfr a Homebrew cask install links into the
	// prefix's bin, which outlives the version directory brew upgrades.
	caskBinary = func() (string, error) {
		var out strings.Builder
		c := brewCommand("--prefix")
		c.Stdout = &out
		if err := runWithin(brewReadWithin, c); err != nil {
			return "", fmt.Errorf("brew --prefix: %w", err)
		}
		return filepath.Join(strings.TrimSpace(out.String()), "bin", release.BinaryName(runtime.GOOS)), nil
	}
	selfExecutable = os.Executable
	// handOver runs the rest of `cyfr update` as the program at path
	// (continueAs, by platform).
	handOver = continueAs
)

// installScript is the install line's first half, which an exact release
// follows as `| CYFR_VERSION=<version> sh`.
const installScript = "curl -fsSL https://raw.githubusercontent.com/cyfrworks/cyfr/main/scripts/install.sh"

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
	// offer and confirmed are the CYFR app's page's (--offer, --confirmed):
	// the change shown and none made, and the confirmation of the change
	// shown; neither takes the program step.
	offer     bool
	confirmed string
}

// handedOver is the status of the new program the program step ran to
// finish `cyfr update` as a child, where a running program cannot be
// replaced by exec (Windows); the child printed its own outcome.
type handedOver struct{ status int }

func (h handedOver) Error() string {
	return fmt.Sprintf("the updated cyfr exited with status %d", h.status)
}

// updateProgram is `cyfr update`'s program step: it brings the installed
// CYFR app and this program to the target release where they are not
// there, then hands the rest of the update over to the new program,
// answering finished once that program has run it (a child, on Windows);
// on Unix a handover that succeeds never returns. The target is
// --version's exact release, older or a pre-release included, else
// release.Latest's (the newest release that is not a pre-release, or while
// none is published the newest pre-release), taken only when
// release.IsNewer says it is newer than this program, so an older line's
// later patch never downgrades and a development build is never replaced.
//
// The installed app is updated by its own road whichever cyfr runs this
// (updateApp): the cyfr inside it is the app's, which only its installer
// replaces. A standalone cyfr, one an install script or a download put
// anywhere else, replaces itself as it always has, so the command a person
// types is never left at the old release in front of the new app. Both
// downloads are verified before anything changes; a Homebrew cask install
// is Homebrew's to change, the app with it.
func updateProgram(ctx context.Context, out io.Writer, o updateOptions) (bool, error) {
	current := version.Version
	if o.version != "" && !release.IsVersion(o.version) {
		return false, fmt.Errorf("--version %q is not a release version (MAJOR.MINOR.PATCH, or with a pre-release, such as 0.6.0 or 0.6.0-alpha.1); nothing was changed", o.version)
	}
	self, err := selfExecutable()
	if err == nil {
		self, err = filepath.EvalSymlinks(self)
	}
	if err != nil {
		return false, fmt.Errorf("cyfr update could not find its own program file (%v); nothing was changed", err)
	}
	// The installed app's road: Homebrew's for a cask install, which
	// installs the app, else this system's installer's. This program is
	// the road's own where it is the cyfr the app carries, or the one the
	// cask links.
	cask := caskInstalled()
	road := appRoadHere()
	if cask {
		road = caskRoad{exact: o.version != ""}
	}
	inApp := isInstalledAppCyfr(self) || (cask && isCaskCyfr(self))
	appThere := cask || inApp || machine.appPresent()
	app := ""
	if appThere {
		app = machine.appRelease()
	}
	// settled says whether the app needs nothing for target.
	settled := func(target string) bool { return !appThere || app == target }

	target, latest, none, err := updateTarget(ctx, current, o.version, settled)
	switch none {
	case devBuild:
		fmt.Fprintf(out, "This cyfr is a development build (%s), which cyfr update does not replace.\n", current)
	case noReleaseYet:
		fmt.Fprintf(out, "No release of CYFR is published yet, so this cyfr (%s) stays.\n", current)
	case onNewest:
		fmt.Fprintf(out, "cyfr %s is the newest release.\n", current)
	case pastNewest:
		fmt.Fprintf(out, "cyfr %s is newer than the newest release, %s, so it stays.\n", current, latest)
	case onExact:
		fmt.Fprintf(out, "This cyfr is release %s already.\n", current)
	}
	if none != 0 || err != nil {
		return false, err
	}
	again := "cyfr update"
	if o.version != "" {
		again += " --version " + target
	}
	if current != target && !inApp {
		if release.IsNewer(current, target) {
			fmt.Fprintf(out, "Installing cyfr %s, older than this cyfr's %s, as --version asks...\n", target, current)
		} else {
			fmt.Fprintf(out, "Updating cyfr from %s to %s...\n", current, target)
		}
	}

	unlock, err := lockUpdate()
	if err != nil {
		return false, err
	}
	defer unlock()
	// The standalone program's release, verified before the app is
	// touched; written only once the app is the target's.
	var binary []byte
	if !inApp && current != target {
		b, err := fetchSelf(ctx, out, self, target, o.version != "")
		if err != nil {
			return false, err
		}
		binary = b
	}
	if !settled(target) {
		if err := updateApp(ctx, out, road, app, target, again); err != nil {
			return false, err
		}
	}
	path := self
	switch {
	case binary != nil:
		if err := replaceExecutable(self, binary); err != nil {
			if appThere {
				return false, fmt.Errorf("The CYFR app is release %s, but this cyfr, %s, could not be replaced (%v); it is still release %s and your CYFR was not touched. Run 'sudo cyfr update' if its directory is not yours to write", target, self, err, current)
			}
			return false, fmt.Errorf("Release %s verified but could not be installed at %s (%v); the program there is unchanged and your CYFR was not touched. Run 'sudo cyfr update' if its directory is not yours to write", target, self, err)
		}
		if appThere {
			fmt.Fprintf(out, "The CYFR app and this cyfr, %s, are release %s.\n", self, target)
		} else {
			fmt.Fprintf(out, "cyfr %s is installed at %s.\n", target, self)
		}
	case cask && inApp:
		p, err := caskBinary()
		if err != nil {
			return false, fmt.Errorf("brew installed cyfr %s, but cyfr update could not find it (%v); your CYFR was not touched. Run 'cyfr update' again", target, err)
		}
		fmt.Fprintf(out, "cyfr %s is installed by Homebrew at %s.\n", target, p)
		path = p
	}
	if current == target {
		// This program is the target's already: it goes on itself.
		return false, nil
	}
	unlock()
	if ctx.Err() != nil {
		return false, fmt.Errorf("cyfr update was interrupted once cyfr %s was installed, before CYFR in this directory was updated; run 'cyfr update' again to update it", target)
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
		return false, fmt.Errorf("cyfr %s is installed at %s, but it could not be started (%v); your CYFR was not touched. Run 'cyfr update' again", target, path, err)
	case status != 0:
		return false, handedOver{status}
	}
	return true, nil
}

// noTarget is why cyfr update has no release to go to: this program is a
// development build, no release is published, it is the newest release
// already, newer than the newest, or the exact release asked for.
type noTarget int

const (
	devBuild noTarget = iota + 1
	noReleaseYet
	onNewest
	pastNewest
	onExact
)

// updateTarget is the release cyfr update goes to from this program's
// release current: exact, --version's, else the newest (release.Latest),
// taken only when release.IsNewer says it is newer than current; settled
// says whether the installed app needs nothing for a release. none says
// why there is no target, and latest is the newest release where it was
// read; err is a newest that could not be looked up.
func updateTarget(ctx context.Context, current, exact string, settled func(string) bool) (target, latest string, none noTarget, err error) {
	if exact != "" {
		if exact == current && settled(exact) {
			return "", "", onExact, nil
		}
		return exact, "", 0, nil
	}
	if !release.IsVersion(current) {
		return "", "", devBuild, nil
	}
	lookup, cancel := context.WithTimeout(ctx, 30*time.Second)
	latest, err = latestRelease(lookup)
	cancel()
	switch {
	case errors.Is(err, release.ErrNoRelease):
		return "", "", noReleaseYet, nil
	case err != nil:
		return "", "", 0, fmt.Errorf("cyfr update could not look up the newest release (%w); nothing was changed", err)
	case latest == current && settled(latest):
		return "", latest, onNewest, nil
	case latest != current && !release.IsNewer(latest, current):
		return "", latest, pastNewest, nil
	}
	return latest, latest, 0, nil
}

// isInstalledAppCyfr is whether the program at path, its links resolved,
// is the cyfr the installed CYFR app carries (appCyfr).
func isInstalledAppCyfr(path string) bool {
	carried, err := appCyfr()
	if err != nil {
		return false
	}
	return samePath(path, carried)
}

// samePath is whether a and b, their links resolved, are one file's
// path; one that does not resolve is no path.
func samePath(a, b string) bool {
	ra, err := filepath.EvalSymlinks(a)
	if err != nil {
		return false
	}
	rb, err := filepath.EvalSymlinks(b)
	return err == nil && ra == rb
}

// packageOf is the package of this system's that installed the program at
// path, its links resolved, as the system's package records say (dpkg's,
// on Linux), or "" when none did. Such a program never rewrites or removes
// itself: the package's tool does both. When the records cannot answer,
// it is an error, and the caller changes nothing. Where there are no dpkg
// records (a system without dpkg, macOS, Windows), no package of CYFR's
// installed it.
func packageOf(path string) (string, error) {
	real, err := filepath.EvalSymlinks(path)
	if err != nil {
		return "", err
	}
	if runtime.GOOS != "linux" {
		return "", nil
	}
	tool, err := exec.LookPath("dpkg-query")
	switch {
	case errors.Is(err, exec.ErrNotFound):
		return "", nil
	case err != nil:
		return "", err
	}
	var stdout, stderr strings.Builder
	query := exec.Command(tool, "--search", "--", real)
	// The words read below are dpkg's untranslated ones.
	query.Env = append(os.Environ(), "LC_ALL=C")
	query.Stdout, query.Stderr = &stdout, &stderr
	err = runWithin(10*time.Second, query)
	out := stdout.String()
	var exit *exec.ExitError
	if errors.As(err, &exit) && exit.ExitCode() == 1 && strings.Contains(stderr.String(), "no path found matching pattern") {
		return "", nil
	}
	if err != nil {
		return "", fmt.Errorf("dpkg-query --search %s: %v", real, err)
	}
	// Each line is "package[, package]: path"; a diversion's lines are not
	// an owner.
	for _, line := range strings.Split(out, "\n") {
		if owners, ok := strings.CutSuffix(line, ": "+real); ok && owners != "" && !strings.HasPrefix(line, "diversion by ") {
			return owners, nil
		}
	}
	return "", fmt.Errorf("dpkg-query --search %s named no package for it", real)
}

// fetchSelf downloads and verifies release target's binary for this
// platform, for the standalone program at self (its links resolved),
// writing nothing. A program a package installed (packageOf), or one
// whose package the records cannot tell, is refused before any download:
// its package's tool replaces it. So is a cyfr inside an app's bundle
// (appBundleOf), which is the app's: rewritten, it would break the
// bundle's signature.
func fetchSelf(ctx context.Context, out io.Writer, self, target string, exact bool) ([]byte, error) {
	if bundle := appBundleOf(self); bundle != "" {
		return nil, fmt.Errorf("This cyfr, %s, is the one inside the CYFR app at %s, which cyfr update does not rewrite; nothing was changed. Install the CYFR app where its installer puts it, then run 'cyfr update'", self, bundle)
	}
	switch owner, err := packageOf(self); {
	case err != nil:
		return nil, fmt.Errorf("cyfr update could not ask this system's package records whether a package installed %s (%v); nothing was changed", self, err)
	case owner != "":
		again := self + " update"
		if exact {
			again += " --version " + target
		}
		return nil, fmt.Errorf("This cyfr, %s, belongs to the package %s, which cyfr update does not change; nothing was changed. Update it with the system's package tool, then run '%s'", self, owner, again)
	}
	fmt.Fprintf(out, "Downloading and verifying release %s for %s/%s...\n", target, runtime.GOOS, runtime.GOARCH)
	fetch, cancel := context.WithTimeout(ctx, fetchBinaryTimeout)
	binary, err := fetchBinary(fetch, target, runtime.GOOS, runtime.GOARCH)
	cancel()
	switch {
	case errors.Is(err, release.ErrUnverified):
		return nil, fmt.Errorf("Release %s did not verify (%v); %s is unchanged and your CYFR was not touched", target, err, self)
	case err != nil:
		return nil, fmt.Errorf("cyfr update could not download release %s (%v); %s is unchanged and your CYFR was not touched. Download it from %s/tag/%s", target, err, self, releasesPage, target)
	}
	return binary, nil
}

// caskRoad is a Homebrew cask install's road: brew replaces the app its
// cask installs, and installs only the release its tap names, the newest
// one that is not a pre-release, so a --version naming another release is
// refused, pointing at the install script. Before anything changes the tap
// is brought up to date and its cask must name the target release and
// exactly the bytes of the release's macOS installer for this
// architecture as the release's signed checksums name them; brew then
// checks what it downloads against that sum.
type caskRoad struct{ exact bool }

// The bounds of brew's steps: its tap's update and its upgrade, which
// downloads the app.
const (
	brewUpdateWithin  = 10 * time.Minute
	brewUpgradeWithin = 30 * time.Minute
)

func (c caskRoad) fetch(ctx context.Context, out io.Writer, _, target string) (*staged, error) {
	if c.exact {
		lookup, cancel := context.WithTimeout(ctx, 30*time.Second)
		latest, err := latestRelease(lookup)
		cancel()
		if err != nil || latest != target {
			return nil, fmt.Errorf("This cyfr was installed by Homebrew, which installs only the release its tap names, the newest one that is not a pre-release; nothing was changed. To run release %s, install it with the install script: %s | CYFR_VERSION=%s sh", target, installScript, target)
		}
	}
	if err := brew(out, brewUpdateWithin, "update"); err != nil {
		return nil, fmt.Errorf("brew update failed (%v); nothing was changed and CYFR runs as it did", err)
	}
	version, sum, err := caskOffer()
	if err != nil {
		return nil, fmt.Errorf("cyfr update could not read the cyfr cask Homebrew offers (%v); nothing was changed and CYFR runs as it did", err)
	}
	if version != target {
		return nil, fmt.Errorf("Homebrew's tap offers cyfr %s, not %s; nothing was changed and CYFR runs as it did. Try 'brew update-reset' and 'cyfr update' again", version, target)
	}
	check, cancel := context.WithTimeout(ctx, fetchBinaryTimeout)
	want, err := appPackageSum(check, target, "darwin", runtime.GOARCH)
	cancel()
	switch {
	case err != nil:
		return nil, fmt.Errorf("The signed checksums of release %s could not be read for the CYFR app (%v); nothing was changed and CYFR runs as it did", target, err)
	case sum != want:
		return nil, fmt.Errorf("Homebrew's cyfr cask names other bytes than release %s's signed installer for this Mac; nothing was changed and CYFR runs as it did", target)
	}
	return &staged{target: target, sum: sum}, nil
}

// elevate takes nothing: Homebrew asks for what it needs itself.
func (caskRoad) elevate(io.Writer, string, bool) (func(), error) { return func() {}, nil }

func (caskRoad) replace(out io.Writer, s *staged, _ bool) error {
	if err := brew(out, brewUpgradeWithin, "upgrade", "--cask", "cyfr"); err != nil {
		return fmt.Errorf("brew upgrade --cask cyfr failed (%w)", err)
	}
	// Homebrew can exit successfully without changing the installed version.
	switch installed := installedCaskVersion(); {
	case installed == "":
		return errors.New("brew upgraded the cyfr cask, but its version could not be read (brew list --cask --versions cyfr)")
	case installed != s.target:
		return fmt.Errorf("brew exited cleanly but the cyfr cask is still %s, not %s. Try 'brew update-reset', or reinstall with 'brew uninstall --cask cyfr && brew install --cask cyfr'", installed, s.target)
	}
	return nil
}

// finish keeps nothing: Homebrew's upgrade is its own.
func (caskRoad) finish(io.Writer, *staged, bool) error { return nil }

func (caskRoad) closesTheBox() ([]string, []string) { return nil, nil }

// brew runs brew with args to its end within its bound, its output this
// update's.
func brew(out io.Writer, within time.Duration, args ...string) error {
	c := brewCommand(args...)
	c.Stdout, c.Stderr = out, os.Stderr
	return runWithin(within, c)
}

// brewCommand is brew with args, Homebrew's own refresh of its taps off:
// the update refreshes the tap once, itself, before it checks the cask's
// sum, and nothing refreshes it between that check and the upgrade.
func brewCommand(args ...string) *exec.Cmd {
	c := exec.Command(brewProgram(), args...)
	c.Env = append(os.Environ(), "HOMEBREW_NO_AUTO_UPDATE=1")
	return c
}

// brewPrefixes are Homebrew's own prefixes, on Apple silicon and on
// Intel Macs, and none elsewhere, where Homebrew installs no app; a
// variable so tests stand in for them.
var brewPrefixes = func() []string {
	if runtime.GOOS == "darwin" {
		return []string{"/opt/homebrew", "/usr/local"}
	}
	return nil
}()

// brewProgram is the brew of the Homebrew prefix whose Caskroom holds
// CYFR's cask, "" where none does: never PATH's, which an app opened from
// the Finder, and the cyfr it starts, do not have, and which may name any
// program.
func brewProgram() string {
	for _, prefix := range brewPrefixes {
		if info, err := os.Stat(filepath.Join(prefix, "Caskroom", "cyfr")); err == nil && info.IsDir() {
			return filepath.Join(prefix, "bin", "brew")
		}
	}
	return ""
}

// brewReadWithin bounds a brew call that only reads.
const brewReadWithin = time.Minute

// isCaskCyfr is whether the program at path is the cyfr the cask links
// (caskBinary).
func isCaskCyfr(path string) bool {
	linked, err := caskBinary()
	return err == nil && samePath(path, linked)
}

// caskOffer is the version and the sha256 of the cyfr cask Homebrew's tap
// offers this Mac, as brew info reads them.
func caskOffer() (version, sum string, err error) {
	c := brewCommand("info", "--cask", "--json=v2", "cyfr")
	var stdout strings.Builder
	c.Stdout = &stdout
	if err := runWithin(time.Minute, c); err != nil {
		return "", "", err
	}
	var info struct {
		Casks []struct {
			Token   string `json:"token"`
			Version string `json:"version"`
			Sha256  string `json:"sha256"`
		} `json:"casks"`
	}
	if err := json.Unmarshal([]byte(stdout.String()), &info); err != nil {
		return "", "", err
	}
	if len(info.Casks) != 1 || info.Casks[0].Token != "cyfr" || !release.IsVersion(info.Casks[0].Version) || info.Casks[0].Sha256 == "" {
		return "", "", errors.New("brew info named no cyfr cask of a release")
	}
	return info.Casks[0].Version, strings.ToLower(info.Casks[0].Sha256), nil
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
	var out strings.Builder
	c := brewCommand("list", "--cask", "--versions", "cyfr")
	c.Stdout = &out
	if err := runWithin(brewReadWithin, c); err != nil {
		return ""
	}
	fields := strings.Fields(strings.TrimSpace(out.String()))
	if len(fields) < 2 {
		return ""
	}
	return fields[len(fields)-1]
}
