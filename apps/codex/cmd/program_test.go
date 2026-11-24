// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"slices"
	"strconv"
	"strings"
	"testing"

	"github.com/cyfr/codex/internal/release"
	"github.com/cyfr/codex/internal/version"
)

// programScenario is `cyfr update` outside a home, from the current
// release against a latest one, its program a file of its own, every
// release lookup, the download and the handover substituted, and a curl
// and an sh on PATH that record any run.
type programScenario struct {
	t       *testing.T
	machine *standIn
	self    string
	ran     string
	lookups int
	fetched []string
	answer  func() ([]byte, error)
	// latestErr is the lookup's error, when it fails.
	latestErr error
	// handed are the handovers made, each its path and arguments, and
	// handStatus and handErr what the handover answers.
	handed     [][]string
	handStatus int
	handErr    error
}

func newProgramScenario(t *testing.T, current, latest string) *programScenario {
	dir := t.TempDir()
	s := &programScenario{t: t, self: filepath.Join(dir, "cyfr"), ran: filepath.Join(t.TempDir(), "ran")}
	// Chmod sets the mode apart from the umask, so the install is seen to
	// keep it.
	if err := errors.Join(os.WriteFile(s.self, []byte("old cyfr"), 0755), os.Chmod(s.self, 0755)); err != nil {
		t.Fatal(err)
	}
	// The stand-in machine, at no terminal, with no CYFR app installed,
	// its PATH one folder holding only a curl and an sh that record any
	// run.
	s.machine = standInMachine(t)
	s.machine.installed, s.machine.app = nil, ""
	askTerminal = func() bool { return false }
	for _, name := range []string{"curl", "sh"} {
		standInLink(t, filepath.Join(os.Getenv("PATH"), name))
	}
	t.Setenv(fakeRecord, s.ran)
	t.Chdir(t.TempDir())
	savedVersion, savedLatest, savedFetch, savedCask, savedSelf, savedHand := version.Version, latestRelease, fetchBinary, caskInstalled, selfExecutable, handOver
	t.Cleanup(func() {
		version.Version, latestRelease, fetchBinary, caskInstalled, selfExecutable, handOver = savedVersion, savedLatest, savedFetch, savedCask, savedSelf, savedHand
	})
	version.Version = current
	latestRelease = func(context.Context) (string, error) {
		s.lookups++
		return latest, s.latestErr
	}
	caskInstalled = func() bool { return false }
	selfExecutable = func() (string, error) { return s.self, nil }
	s.answer = func() ([]byte, error) { return []byte("new cyfr"), nil }
	fetchBinary = func(_ context.Context, v, goos, goarch string) ([]byte, error) {
		s.fetched = append(s.fetched, v)
		body, err := s.answer()
		if err != nil {
			return nil, err
		}
		return append(body, " "+v...), nil
	}
	handOver = func(path string, args []string) (int, error) {
		s.handed = append(s.handed, append([]string{path}, args...))
		return s.handStatus, s.handErr
	}
	// No test closes or opens an app of the machine it runs on, nor takes
	// the machine's own update lock.
	savedQuit, savedReopen, savedLock := quitApp, reopenApp, updateLockPath
	t.Cleanup(func() { quitApp, reopenApp, updateLockPath = savedQuit, savedReopen, savedLock })
	updateLockPath = filepath.Join(t.TempDir(), "update.lock")
	quitApp = func() (bool, error) { return false, nil }
	reopenApp = func() error { return errors.New("a test opened the installed app") }
	return s
}

// resolvedPath is p with its links resolved, as the update names the
// program it installs: macOS's temporary directory lies under /var, a link
// to /private/var.
func resolvedPath(t *testing.T, p string) string {
	t.Helper()
	resolved, err := filepath.EvalSymlinks(p)
	if err != nil {
		t.Fatal(err)
	}
	return resolved
}

func (s *programScenario) run(o updateOptions) (string, error) {
	return s.runContext(context.Background(), o)
}

func (s *programScenario) runContext(ctx context.Context, o updateOptions) (string, error) {
	var out bytes.Buffer
	err := runUpdate(ctx, &out, &out, o)
	return out.String(), err
}

// unchanged fails unless the program is the old one, nothing else lies in
// its directory and nothing was handed over.
func (s *programScenario) unchanged() {
	s.t.Helper()
	if got := read(s.t, s.self); got != "old cyfr" {
		s.t.Errorf("the program holds %q, want the old one", got)
	}
	if len(s.handed) != 0 {
		s.t.Errorf("cyfr update handed over: %v", s.handed)
	}
	s.alone()
}

func (s *programScenario) alone() {
	s.t.Helper()
	if got := read(s.t, s.ran); got != "<absent>" {
		s.t.Errorf("cyfr update ran %q", got)
	}
	entries, _ := os.ReadDir(filepath.Dir(s.self))
	if len(entries) != 1 {
		var names []string
		for _, e := range entries {
			names = append(names, e.Name())
		}
		s.t.Errorf("the program's directory holds %v", names)
	}
}

// installed fails unless the program is release target's, with its mode
// kept, and the update was handed over to it once, as args.
func (s *programScenario) installed(target string, args ...string) {
	s.t.Helper()
	if !slices.Equal(s.fetched, []string{target}) {
		s.t.Errorf("cyfr update fetched %v, want %s", s.fetched, target)
	}
	if got := read(s.t, s.self); got != "new cyfr "+target {
		s.t.Errorf("the program holds %q, want release %s's", got, target)
	}
	if info, err := os.Stat(s.self); err != nil || info.Mode().Perm() != 0755 {
		s.t.Errorf("the program's mode is %v (error %v), want 0755", info.Mode().Perm(), err)
	}
	self := resolvedPath(s.t, s.self)
	want := append([]string{self, self, "update", "--continue-as", target}, args...)
	if len(s.handed) != 1 || !slices.Equal(s.handed[0], want) {
		s.t.Errorf("cyfr update handed over %v, want once as %v", s.handed, want)
	}
	s.alone()
}

// The newest release is installed only when release.IsNewer says it is
// newer than this program: an equal one, an older line's later patch, a
// release older than a pre-release and a development build install
// nothing, and the update goes on to the home step, which outside a home
// says there is none. A newer one is installed, a pre-release's own
// release among them, and the update is handed to it.
func TestUpdateInstallsOnlyANewerRelease(t *testing.T) {
	for _, c := range []struct {
		current, latest string
		installs        bool
		says            string
	}{
		{"0.9.0", "0.9.0", false, "cyfr 0.9.0 is the newest release."},
		{"0.9.1", "0.8.7", false, "cyfr 0.9.1 is newer than the newest release, 0.8.7, so it stays."},
		{"0.6.0-alpha.1", "0.5.8", false, "cyfr 0.6.0-alpha.1 is newer than the newest release, 0.5.8"},
		{"dev", "0.9.0", false, "This cyfr is a development build (dev), which cyfr update does not replace."},
		{"0.9.0", "0.10.0", true, "Updating cyfr from 0.9.0 to 0.10.0..."},
		{"0.6.0-alpha.1", "0.6.0", true, "Updating cyfr from 0.6.0-alpha.1 to 0.6.0..."},
	} {
		t.Run(c.current+" to "+c.latest, func(t *testing.T) {
			s := newProgramScenario(t, c.current, c.latest)
			out, err := s.run(updateOptions{})
			if err != nil || !strings.Contains(out, c.says) {
				t.Fatalf("cyfr update answered %v:\n%s", err, out)
			}
			if !c.installs {
				if len(s.fetched) != 0 {
					t.Errorf("cyfr update fetched %v", s.fetched)
				}
				if !strings.Contains(out, "There is no CYFR in this directory") {
					t.Errorf("cyfr update did not go on to say there is no home:\n%s", out)
				}
				s.unchanged()
				return
			}
			if !strings.Contains(out, "cyfr "+c.latest+" is installed at "+resolvedPath(t, s.self)+".") {
				t.Errorf("cyfr update did not say where it installed:\n%s", out)
			}
			if strings.Contains(out, "There is no CYFR") {
				t.Errorf("the old program went on past the handover:\n%s", out)
			}
			s.installed(c.latest)
		})
	}
}

// --version installs exactly the release it names, a pre-release and an
// older release included, without looking up the newest, and says when it
// is older; the release this program is already installs nothing.
func TestUpdateVersionInstallsExactlyThatRelease(t *testing.T) {
	for _, c := range []struct {
		current, version string
		installs         bool
		says             string
	}{
		{"0.9.0", "0.10.0-rc.1", true, "Updating cyfr from 0.9.0 to 0.10.0-rc.1..."},
		{"0.9.0", "0.8.0", true, "Installing cyfr 0.8.0, older than this cyfr's 0.9.0, as --version asks..."},
		{"0.6.0", "0.6.0-alpha.1", true, "Installing cyfr 0.6.0-alpha.1, older than this cyfr's 0.6.0"},
		{"dev", "0.9.0", true, "Updating cyfr from dev to 0.9.0..."},
		{"0.9.0", "0.9.0", false, "This cyfr is release 0.9.0 already."},
	} {
		t.Run(c.current+" to "+c.version, func(t *testing.T) {
			s := newProgramScenario(t, c.current, "1.0.0")
			out, err := s.run(updateOptions{version: c.version, yes: true})
			if err != nil || !strings.Contains(out, c.says) {
				t.Fatalf("cyfr update --version %s answered %v:\n%s", c.version, err, out)
			}
			if s.lookups != 0 {
				t.Errorf("cyfr update --version looked up the newest release %d times", s.lookups)
			}
			if !c.installs {
				s.unchanged()
				return
			}
			s.installed(c.version, "--yes")
		})
	}
}

// A --version that is no release version refuses before any request; so
// does a lookup that fails. A lookup that finds only pre-releases says how
// to name one and goes on with this program.
func TestUpdateRefusesBeforeAnyRequest(t *testing.T) {
	for _, version := range []string{"v0.9.1", "0.9", "0.9.1+build.1", "latest", "0.9.1-"} {
		s := newProgramScenario(t, "0.9.0", "0.9.1")
		out, err := s.run(updateOptions{version: version})
		if err == nil || !strings.Contains(err.Error(), "is not a release version") || !strings.Contains(err.Error(), "nothing was changed") {
			t.Errorf("cyfr update --version %q answered %v:\n%s", version, err, out)
		}
		if s.lookups != 0 || len(s.fetched) != 0 {
			t.Errorf("cyfr update --version %q made %d lookups and fetched %v", version, s.lookups, s.fetched)
		}
		s.unchanged()
	}

	s := newProgramScenario(t, "0.9.0", "")
	s.latestErr = errors.New("dial tcp: lookup api.github.com: no such host")
	if out, err := s.run(updateOptions{}); err == nil || !strings.Contains(err.Error(), "could not look up the newest release") || strings.Contains(out, "no CYFR") {
		t.Errorf("a failed lookup answered %v:\n%s", err, out)
	}
	s.unchanged()

	s = newProgramScenario(t, "0.6.0-alpha.1", "")
	s.latestErr = release.ErrNoRelease
	out, err := s.run(updateOptions{})
	if err != nil || !strings.Contains(out, "No release of CYFR is published yet, so this cyfr (0.6.0-alpha.1) stays.\n") || !strings.Contains(out, "There is no CYFR in this directory") {
		t.Errorf("no published release answered %v:\n%s", err, out)
	}
	s.unchanged()
}

// A release that does not verify, or does not download, leaves the
// program as it was and hands nothing over; no installer runs.
func TestUpdateRefusesWhatDoesNotVerify(t *testing.T) {
	for name, c := range map[string]struct {
		err  error
		says string
	}{
		"unverified": {fmt.Errorf("%w: cyfr_0.9.1_linux_amd64.tar.gz does not match the release's signed checksums.txt", release.ErrUnverified), "did not verify"},
		"transport":  {errors.New("download https://github.com/x: HTTP 503"), "could not download release 0.9.1"},
	} {
		t.Run(name, func(t *testing.T) {
			s := newProgramScenario(t, "0.9.0", "0.9.1")
			s.answer = func() ([]byte, error) { return nil, c.err }
			out, err := s.run(updateOptions{})
			if err == nil || !strings.Contains(err.Error(), c.says) || !strings.Contains(err.Error(), "; "+resolvedPath(t, s.self)+" is unchanged and your CYFR was not touched") {
				t.Fatalf("cyfr update answered %v:\n%s", err, out)
			}
			s.unchanged()
		})
	}

	// A directory that is not writable keeps the program as it was.
	s := newProgramScenario(t, "0.9.0", "0.9.1")
	if os.Geteuid() == 0 {
		t.Skip("root writes any directory")
	}
	if err := os.Chmod(filepath.Dir(s.self), 0555); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chmod(filepath.Dir(s.self), 0755) })
	if out, err := s.run(updateOptions{}); err == nil || !strings.Contains(err.Error(), "could not be installed") || !strings.Contains(err.Error(), "'sudo cyfr update'") {
		t.Fatalf("cyfr update answered %v:\n%s", err, out)
	}
	s.unchanged()
}

// After the install: a handover that cannot start the new program says
// so, the program replaced and the home untouched; a new program that
// ran as a child and failed ends the update with its status, printed by
// it and not again; an interrupt that arrived during the install hands
// nothing over.
func TestUpdateHandsOverToTheInstalledProgram(t *testing.T) {
	s := newProgramScenario(t, "0.9.0", "0.9.1")
	s.handErr = errors.New("exec format error")
	_, err := s.run(updateOptions{})
	if err == nil || !strings.Contains(err.Error(), "cyfr 0.9.1 is installed at "+resolvedPath(t, s.self)+", but it could not be started (exec format error); your CYFR was not touched") {
		t.Errorf("a failed handover answered %v", err)
	}
	if got := read(t, s.self); got != "new cyfr 0.9.1" {
		t.Errorf("the program holds %q after a failed handover, want the installed one", got)
	}

	s = newProgramScenario(t, "0.9.0", "0.9.1")
	s.handStatus = 3
	_, err = s.run(updateOptions{})
	if child := (handedOver{}); !errors.As(err, &child) || ExitStatus(err) != 3 {
		t.Errorf("a child ending with status 3 answered %v, exit %d", err, ExitStatus(err))
	}

	s = newProgramScenario(t, "0.9.0", "0.9.1")
	ctx, cancel := context.WithCancel(context.Background())
	s.answer = func() ([]byte, error) {
		cancel()
		return []byte("new cyfr"), nil
	}
	_, err = s.runContext(ctx, updateOptions{})
	if err == nil || !strings.Contains(err.Error(), "interrupted once cyfr 0.9.1 was installed, before CYFR in this directory was updated") || len(s.handed) != 0 {
		t.Errorf("an interrupt during the install answered %v, handovers %v", err, s.handed)
	}
}

// A directory that holds a compose file is a CYFR, whether `cyfr init`
// wrote it or a source checkout holds it, and the update goes on to the
// directory's step there, which begins with the manifest fetch. Without
// one the update ends with the program, naming the files it looked for.
func TestUpdateGoesOnInADirectoryThatHoldsAComposeFile(t *testing.T) {
	s := newProgramScenario(t, "0.9.0", "0.9.0")
	savedFetch := fetchManifest
	t.Cleanup(func() { fetchManifest = savedFetch })
	offline := errors.New("the manifest fetch is offline")
	fetchManifest = func(context.Context, string) (*release.Manifest, error) { return nil, offline }

	out, err := s.run(updateOptions{})
	if err != nil || !strings.Contains(out, "There is no CYFR in this directory") || !strings.Contains(out, "it holds no compose file (") || !strings.Contains(out, "docker-compose.yml") {
		t.Fatalf("cyfr update in a directory with no compose file answered %v:\n%s", err, out)
	}
	if err := os.WriteFile("docker-compose.yml", []byte("services: {}\n"), 0644); err != nil {
		t.Fatal(err)
	}
	out, err = s.run(updateOptions{})
	if err == nil || !strings.Contains(err.Error(), offline.Error()) || strings.Contains(out, "There is no CYFR") {
		t.Fatalf("cyfr update beside a compose file answered %v:\n%s", err, out)
	}
	s.unchanged()
}

// The program a handover starts skips the program step, and refuses to go
// on unless it is the release the handover names.
func TestContinueAsChecksTheRelease(t *testing.T) {
	s := newProgramScenario(t, "0.9.1", "1.0.0")
	out, err := s.run(updateOptions{continueAs: "0.9.1"})
	if err != nil || s.lookups != 0 || !strings.Contains(out, "There is no CYFR in this directory") || strings.Contains(out, "newest release") {
		t.Errorf("the handed-over program answered %v after %d lookups:\n%s", err, s.lookups, out)
	}
	s.unchanged()

	s = newProgramScenario(t, "0.9.0", "1.0.0")
	out, err = s.run(updateOptions{continueAs: "0.9.1"})
	if err == nil || !strings.Contains(err.Error(), "The cyfr at "+s.self+" is 0.9.0, not release 0.9.1 that cyfr update installed; your CYFR was not touched") || s.lookups != 0 {
		t.Errorf("a program of another release answered %v:\n%s", err, out)
	}
	s.unchanged()
}

// fakeBrew puts a brew on PATH, this test binary (runFakeBrew), that
// records each run in its directory's log, answers `--prefix` with its
// directory, `list --cask cyfr` as installed and `list --cask --versions
// cyfr` with the version in its directory's version file, which `upgrade
// --cask cyfr` sets to upgradeTo.
func fakeBrew(t *testing.T, installed, upgradeTo string) string {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("the fake brew is a link to this test binary, which Windows makes only with a privilege")
	}
	dir := t.TempDir()
	if err := errors.Join(
		os.WriteFile(filepath.Join(dir, "version"), []byte(installed+"\n"), 0644),
		os.WriteFile(filepath.Join(dir, "upgrade-to"), []byte(upgradeTo+"\n"), 0644),
		os.WriteFile(filepath.Join(dir, "offers"), []byte(upgradeTo+"\n"), 0644),
		os.WriteFile(filepath.Join(dir, "sha256"), []byte(caskSum+"\n"), 0644),
	); err != nil {
		t.Fatal(err)
	}
	// The release's signed checksums name the cask's sum for the Mac's
	// installer, and the app's own cyfr answers the release brew installed.
	savedSum, savedRelease := appPackageSum, machine.appRelease
	t.Cleanup(func() { appPackageSum, machine.appRelease = savedSum, savedRelease })
	appPackageSum = func(_ context.Context, v, goos, goarch string) (string, error) {
		if goos != "darwin" || goarch != runtime.GOARCH {
			return "", fmt.Errorf("the sum of %s's installer for %s/%s was asked", v, goos, goarch)
		}
		return caskSum, nil
	}
	machine.appRelease = func() string { return strings.TrimSpace(read(t, filepath.Join(dir, "version"))) }
	standInLink(t, filepath.Join(dir, "brew"))
	t.Setenv(fakeBrewDir, dir)
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	if found, err := exec.LookPath("brew"); err != nil || found != filepath.Join(dir, "brew") {
		t.Fatalf("PATH's brew is %q (%v), not the stand-in", found, err)
	}
	return dir
}

// A Homebrew cask install updates through brew and hands the update to
// the cyfr brew links into its prefix, once brew reports the release
// installed; brew left on another release hands nothing over. A --version
// other than the tap's release, the newest one, is refused before brew
// standInDpkg puts a dpkg-query in the stand-in machine's one PATH
// folder, on a system whose language is German: it names owned's package
// for each of its paths, says no package installed any other, or,
// failing, fails as a damaged database does. As dpkg does, it says its
// words in German, a diversion's line and "no path found" among them,
// unless LC_ALL is C; a package's line is the same in every language.
func standInDpkg(t *testing.T, owned map[string]string, failing bool) {
	t.Helper()
	if runtime.GOOS != "linux" {
		t.Skip("the package records are asked on Linux alone")
	}
	t.Setenv("LANG", "de_DE.UTF-8")
	t.Setenv("LC_ALL", "de_DE.UTF-8")
	script := "#!/bin/sh\n[ \"$1\" = --search ] && [ \"$2\" = -- ] || exit 9\n" +
		"if [ \"$LC_ALL\" = C ]; then diverted='diversion by other from'; none='no path found matching pattern'\n" +
		"else diverted='Umleitung durch other von'; none='kein Pfad gefunden, der auf Muster passt:'; fi\n"
	if failing {
		script += "echo 'dpkg-query: error: parsing file /var/lib/dpkg/status' >&2\nexit 2\n"
	} else {
		script += "case \"$3\" in\n"
		for path, pkg := range owned {
			script += fmt.Sprintf("'%s') echo \"$diverted: %s\"; echo '%s: %s' ;;\n", path, path, pkg, path)
		}
		script += "*) echo \"dpkg-query: $none $3\" >&2; exit 1 ;;\nesac\n"
	}
	if err := os.WriteFile(filepath.Join(os.Getenv("PATH"), "dpkg-query"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
}

// A cyfr the package records name as another package's is never
// rewritten, reached by its own path or by a link, and the refusal names
// the second command exactly: that program by its own path, with
// --version where it was asked. The app's own cyfr is the app's road's
// (TestUpdateBringsTheInstalledAppByItsRoad).
func TestUpdateLeavesAPackagesProgramToThePackage(t *testing.T) {
	for _, c := range []struct {
		name    string
		byLink  bool
		options updateOptions
	}{
		{"its own path", false, updateOptions{}},
		{"a link to it, the newest release", true, updateOptions{}},
		{"a link to it, an exact release", true, updateOptions{version: "1.2.0"}},
	} {
		t.Run(c.name, func(t *testing.T) {
			s := newProgramScenario(t, "1.0.0", "1.1.0")
			standInDpkg(t, map[string]string{s.self: "cyfr-other"}, false)
			if c.byLink {
				link := filepath.Join(t.TempDir(), "cyfr")
				if err := os.Symlink(s.self, link); err != nil {
					t.Fatal(err)
				}
				selfExecutable = func() (string, error) { return link, nil }
			}
			again := s.self + " update"
			if c.options.version != "" {
				again += " --version " + c.options.version
			}
			_, err := s.run(c.options)
			want := "This cyfr, " + s.self + ", belongs to the package cyfr-other, which cyfr update does not change; nothing was changed. Update it with the system's package tool, then run '" + again + "'"
			if err == nil || err.Error() != want {
				t.Errorf("cyfr update answered %v, want %q", err, want)
			}
			if len(s.fetched) != 0 || len(s.handed) != 0 || read(t, s.self) != "old cyfr" {
				t.Errorf("the package's cyfr was fetched %v, handed over %v or changed", s.fetched, s.handed)
			}
		})
	}
}

// A cyfr no package installed is updated, a file named like the app's
// code beside it or not, and so is one on a system with no package
// records to ask; one whose records cannot answer changes nothing.
func TestUpdateAsksThePackageRecordsAlone(t *testing.T) {
	for _, c := range []struct {
		name     string
		dpkg     string // "none", "says no" or "fails"
		appAsar  bool
		replaced bool
	}{
		{"an install script's, an app.asar beside it", "says no", true, true},
		{"an install script's, no package records", "none", false, true},
		{"package records that fail", "fails", true, false},
	} {
		t.Run(c.name, func(t *testing.T) {
			s := newProgramScenario(t, "1.0.0", "1.1.0")
			switch c.dpkg {
			case "says no":
				standInDpkg(t, nil, false)
			case "fails":
				standInDpkg(t, nil, true)
			}
			if c.appAsar {
				if err := os.WriteFile(filepath.Join(filepath.Dir(s.self), "app.asar"), []byte("the app"), 0644); err != nil {
					t.Fatal(err)
				}
			}
			_, err := s.run(updateOptions{})
			if c.replaced {
				if err != nil || read(t, s.self) != "new cyfr 1.1.0" || len(s.handed) != 1 {
					t.Errorf("cyfr update answered %v, handed over %v, the program holds %q", err, s.handed, read(t, s.self))
				}
				return
			}
			if err == nil || !strings.HasPrefix(err.Error(), "cyfr update could not ask this system's package records whether a package installed "+s.self+" (") ||
				!strings.HasSuffix(err.Error(), "); nothing was changed") || len(s.fetched) != 0 || read(t, s.self) != "old cyfr" {
				t.Errorf("cyfr update answered %v, fetched %v, the program holds %q", err, s.fetched, read(t, s.self))
			}
		})
	}
}

func TestUpdateThroughHomebrew(t *testing.T) {
	brewLog := func(dir string) string { return strings.TrimSpace(read(t, filepath.Join(dir, "log"))) }
	restore := caskInstalled
	t.Cleanup(func() { caskInstalled = restore })

	// The cask's own cyfr, the one it links into the prefix's bin: brew
	// replaces it with the app, and the update goes on as it.
	s := newProgramScenario(t, "0.9.0", "0.10.0")
	dir := fakeBrew(t, "0.9.0", "0.10.0")
	caskInstalled = restore
	linked := filepath.Join(dir, "bin", "cyfr")
	writeFile(t, linked, "the cask's cyfr")
	selfExecutable = func() (string, error) { return linked, nil }
	out, err := s.run(updateOptions{})
	want := resolvedPath(t, linked)
	if err != nil || len(s.handed) != 1 || !slices.Equal(s.handed[0], []string{want, want, "update", "--continue-as", "0.10.0"}) {
		t.Fatalf("cyfr update through brew answered %v, handovers %v:\n%s", err, s.handed, out)
	}
	if got := brewLog(dir); got != "list --cask cyfr\n--prefix\nupdate\ninfo --cask --json=v2 cyfr\nupgrade --cask cyfr\nlist --cask --versions cyfr\n--prefix" {
		t.Errorf("brew ran:\n%s", got)
	}
	if len(s.fetched) != 0 || read(t, linked) != "the cask's cyfr" {
		t.Errorf("the cask's cyfr was downloaded %v or replaced by cyfr update itself", s.fetched)
	}

	// A standalone cyfr beside the cask is never left behind: it is
	// verified first and replaced once brew has installed the release.
	s = newProgramScenario(t, "0.9.0", "0.10.0")
	dir = fakeBrew(t, "0.9.0", "0.10.0")
	caskInstalled = restore
	out, err = s.run(updateOptions{})
	if err != nil {
		t.Fatalf("cyfr update beside a cask answered %v:\n%s", err, out)
	}
	s.installed("0.10.0")
	if got := brewLog(dir); got != "list --cask cyfr\n--prefix\nupdate\ninfo --cask --json=v2 cyfr\nupgrade --cask cyfr\nlist --cask --versions cyfr" {
		t.Errorf("brew ran:\n%s", got)
	}
	if want := "The CYFR app and this cyfr, " + resolvedPath(t, s.self) + ", are release 0.10.0.\n"; !strings.Contains(out, want) {
		t.Errorf("the update did not say %q:\n%s", want, out)
	}

	// A tap that still offers the old release changes nothing.
	s = newProgramScenario(t, "0.9.0", "0.10.0")
	dir = fakeBrew(t, "0.9.0", "0.9.0")
	caskInstalled = restore
	if _, err := s.run(updateOptions{}); err == nil || !strings.HasPrefix(err.Error(), "Homebrew's tap offers cyfr 0.9.0, not 0.10.0; nothing was changed") || len(s.handed) != 0 {
		t.Errorf("a tap on the old release answered %v, handovers %v", err, s.handed)
	}
	if got := brewLog(dir); got != "list --cask cyfr\n--prefix\nupdate\ninfo --cask --json=v2 cyfr" {
		t.Errorf("brew ran for a tap on the old release:\n%s", got)
	}

	// brew that exits cleanly on the old release is not taken for the new.
	s = newProgramScenario(t, "0.9.0", "0.10.0")
	dir = fakeBrew(t, "0.9.0", "0.9.0")
	writeFile(t, filepath.Join(dir, "offers"), "0.10.0\n")
	caskInstalled = restore
	if _, err := s.run(updateOptions{}); err == nil || !strings.Contains(err.Error(), "brew exited cleanly but the cyfr cask is still 0.9.0, not 0.10.0.") ||
		!strings.Contains(err.Error(), "the CYFR app is release 0.9.0; your CYFR was not touched") || len(s.handed) != 0 || read(t, s.self) != "old cyfr" {
		t.Errorf("brew left on the old release answered %v, handovers %v", err, s.handed)
	}

	// A tap whose cask names other bytes than the release's signed
	// installer changes nothing: brew never upgrades.
	s = newProgramScenario(t, "0.9.0", "0.10.0")
	dir = fakeBrew(t, "0.9.0", "0.10.0")
	caskInstalled = restore
	writeFile(t, filepath.Join(dir, "sha256"), strings.Repeat("0", 64))
	if _, err := s.run(updateOptions{}); err == nil || err.Error() != "Homebrew's cyfr cask names other bytes than release 0.10.0's signed installer for this Mac; nothing was changed and CYFR runs as it did" || len(s.handed) != 0 {
		t.Errorf("a cask of other bytes answered %v, handovers %v", err, s.handed)
	}
	if got := brewLog(dir); got != "list --cask cyfr\n--prefix\nupdate\ninfo --cask --json=v2 cyfr" {
		t.Errorf("brew ran for a cask of other bytes:\n%s", got)
	}

	s = newProgramScenario(t, "0.9.0", "0.10.0")
	dir = fakeBrew(t, "0.9.0", "0.10.0")
	caskInstalled = restore
	_, err = s.run(updateOptions{version: "0.10.0-rc.1"})
	if err == nil || !strings.Contains(err.Error(), "installed by Homebrew") || !strings.Contains(err.Error(), "CYFR_VERSION=0.10.0-rc.1 sh") || len(s.handed) != 0 {
		t.Errorf("--version beside a cask install answered %v", err)
	}
	if got := brewLog(dir); got != "list --cask cyfr\n--prefix" || read(t, s.self) != "old cyfr" {
		t.Errorf("brew ran for a refused --version, or the standalone cyfr changed:\n%s", got)
	}

	s = newProgramScenario(t, "0.9.0", "0.10.0")
	fakeBrew(t, "0.9.0", "0.10.0")
	caskInstalled = restore
	if _, err := s.run(updateOptions{version: "0.10.0"}); err != nil || len(s.handed) != 1 {
		t.Errorf("--version naming the tap's release answered %v, handovers %v", err, s.handed)
	}
}

// caskSum is the sha256 the fake brew's cask names and the release's
// signed checksums name for the Mac's installer.
const caskSum = "5a1e5a1e5a1e5a1e5a1e5a1e5a1e5a1e5a1e5a1e5a1e5a1e5a1e5a1e5a1e5a1e"

// handoverDir is where the handover scenario (TestMain) finds the program
// file it replaces and writes what the program it hands over to saw.
const handoverDir = "CYFR_CMD_TEST_HANDOVER_DIR"

// handoverRecord is what the program a handover started saw.
type handoverRecord struct {
	Args   []string `json:"args"`
	PID    int      `json:"pid"`
	Marker string   `json:"marker"`
}

// The real handover: the cyfr process installs release 0.10.0, whose
// program is this test binary, and goes on as it, with the program file
// as its name, `update --continue-as 0.10.0` and the flags given, the
// environment and the output kept, the status it exits with the process's.
// On Unix it is the same process (exec); on Windows a child the first
// waits for.
func TestUpdateHandsOverForReal(t *testing.T) {
	dir := t.TempDir()
	self := filepath.Join(dir, release.BinaryName(runtime.GOOS))
	if err := os.WriteFile(self, []byte("old cyfr"), 0755); err != nil {
		t.Fatal(err)
	}
	t.Setenv(handoverDir, dir)
	t.Setenv("CYFR_CMD_TEST_HANDOVER_MARKER", "kept")
	stdout, stderr, status := runAsCyfr(t, "handover", t.TempDir(), "update", "--yes")
	self = resolvedPath(t, self)
	if status != 7 {
		t.Fatalf("the update exited %d, want the new program's 7:\n%s\n%s", status, stdout, stderr)
	}
	for _, line := range []string{"Updating cyfr from 0.9.0 to 0.10.0...", "cyfr 0.10.0 is installed at " + self + ".", "the new program ran"} {
		if !strings.Contains(stdout, line) {
			t.Errorf("the output lacks %q:\n%s", line, stdout)
		}
	}
	if stderr != "" {
		t.Errorf("the update printed on stderr:\n%s", stderr)
	}
	var record handoverRecord
	if err := json.Unmarshal([]byte(read(t, filepath.Join(dir, "record.json"))), &record); err != nil {
		t.Fatalf("the new program left no record: %v", err)
	}
	if want := []string{self, "update", "--continue-as", "0.10.0", "--yes"}; !slices.Equal(record.Args, want) {
		t.Errorf("the new program ran as %q, want %q", record.Args, want)
	}
	if record.Marker != "kept" {
		t.Errorf("the new program's environment lost the marker: %q", record.Marker)
	}
	first, err := strconv.Atoi(read(t, filepath.Join(dir, "first.pid")))
	if err != nil {
		t.Fatal(err)
	}
	if same := record.PID == first; same != (runtime.GOOS != "windows") {
		t.Errorf("the new program ran as process %d, the first as %d", record.PID, first)
	}
}

// runHandover is TestMain's handover scenario: the cyfr process from
// release 0.9.0, the newest release 0.10.0, its program file the one in
// handoverDir and the archive's program this test binary, the handover
// real.
func runHandover() int {
	dir := os.Getenv(handoverDir)
	test, err := os.Executable()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 98
	}
	binary, err := os.ReadFile(test)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 98
	}
	version.Version = "0.9.0"
	latestRelease = func(context.Context) (string, error) { return "0.10.0", nil }
	caskInstalled = func() bool { return false }
	machine.appPresent = func() bool { return false }
	updateLockPath = filepath.Join(dir, "update.lock")
	selfExecutable = func() (string, error) { return filepath.Join(dir, release.BinaryName(runtime.GOOS)), nil }
	fetchBinary = func(context.Context, string, string, string) ([]byte, error) { return binary, nil }
	if err := os.WriteFile(filepath.Join(dir, "first.pid"), []byte(strconv.Itoa(os.Getpid())), 0644); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 98
	}
	return Main()
}

// recordHandover is the program a handover started, as TestMain runs it:
// it writes what it saw beside the program file and exits 7.
func recordHandover() int {
	data, err := json.Marshal(handoverRecord{Args: os.Args, PID: os.Getpid(), Marker: os.Getenv("CYFR_CMD_TEST_HANDOVER_MARKER")})
	if err == nil {
		err = os.WriteFile(filepath.Join(os.Getenv(handoverDir), "record.json"), data, 0644)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 98
	}
	fmt.Println("the new program ran")
	return 7
}
