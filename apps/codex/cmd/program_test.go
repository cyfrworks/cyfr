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
	bin := t.TempDir()
	for _, name := range []string{"curl", "sh"} {
		if err := os.WriteFile(filepath.Join(bin, name), []byte("#!/bin/sh\necho \"$0 $*\" >> "+s.ran+"\n"), 0755); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("PATH", bin)
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
	if err != nil || !strings.Contains(out, "No release of CYFR is published yet apart from pre-releases, so this cyfr (0.6.0-alpha.1) stays; name one with 'cyfr update --version <version>'") || !strings.Contains(out, "There is no CYFR in this directory") {
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

// fakeBrew puts a brew on PATH, in shell builtins alone since the
// scenario's PATH holds no other tools, that records each run in its
// directory's log, answers `--prefix` with its directory, `list --cask cyfr` as
// installed and `list --cask --versions cyfr` with the version in its
// directory's version file, which `upgrade --cask cyfr` sets to upgradeTo.
func fakeBrew(t *testing.T, installed, upgradeTo string) string {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("the fake brew is a shell script")
	}
	dir := t.TempDir()
	script := `#!/bin/sh
dir='` + dir + `'
echo "$*" >> "$dir/log"
case "$*" in
  --prefix) echo "$dir" ;;
  "list --cask --versions cyfr") read -r v < "$dir/version"; echo "cyfr $v" ;;
  "list --cask cyfr") ;;
  "upgrade --cask cyfr") echo "` + upgradeTo + `" > "$dir/version" ;;
  update) ;;
  *) exit 1 ;;
esac
`
	if err := errors.Join(
		os.WriteFile(filepath.Join(dir, "brew"), []byte(script), 0755),
		os.WriteFile(filepath.Join(dir, "version"), []byte(installed+"\n"), 0644),
	); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	return dir
}

// A Homebrew cask install updates through brew and hands the update to
// the cyfr brew links into its prefix, once brew reports the release
// installed; brew left on another release hands nothing over. A --version
// other than the tap's release, the newest one, is refused before brew
// runs, naming the install script.
func TestUpdateThroughHomebrew(t *testing.T) {
	brewLog := func(dir string) string { return strings.TrimSpace(read(t, filepath.Join(dir, "log"))) }
	restore := caskInstalled
	t.Cleanup(func() { caskInstalled = restore })

	s := newProgramScenario(t, "0.9.0", "0.10.0")
	dir := fakeBrew(t, "0.9.0", "0.10.0")
	caskInstalled = restore
	out, err := s.run(updateOptions{})
	want := filepath.Join(dir, "bin", "cyfr")
	if err != nil || len(s.handed) != 1 || !slices.Equal(s.handed[0], []string{want, want, "update", "--continue-as", "0.10.0"}) {
		t.Fatalf("cyfr update through brew answered %v, handovers %v:\n%s", err, s.handed, out)
	}
	if got := brewLog(dir); got != "list --cask cyfr\nupdate\nupgrade --cask cyfr\nlist --cask --versions cyfr\n--prefix" {
		t.Errorf("brew ran:\n%s", got)
	}
	if len(s.fetched) != 0 || read(t, s.self) != "old cyfr" {
		t.Errorf("a cask install downloaded %v or replaced its program itself", s.fetched)
	}

	s = newProgramScenario(t, "0.9.0", "0.10.0")
	fakeBrew(t, "0.9.0", "0.9.0")
	caskInstalled = restore
	if _, err := s.run(updateOptions{}); err == nil || !strings.Contains(err.Error(), "the cyfr cask is still 0.9.0, not 0.10.0; your CYFR was not touched") || len(s.handed) != 0 {
		t.Errorf("brew left on the old release answered %v, handovers %v", err, s.handed)
	}

	s = newProgramScenario(t, "0.9.0", "0.10.0")
	dir = fakeBrew(t, "0.9.0", "0.10.0")
	caskInstalled = restore
	_, err = s.run(updateOptions{version: "0.10.0-rc.1"})
	if err == nil || !strings.Contains(err.Error(), "installed by Homebrew") || !strings.Contains(err.Error(), "CYFR_VERSION=0.10.0-rc.1 sh") || len(s.handed) != 0 {
		t.Errorf("--version beside a cask install answered %v", err)
	}
	if got := brewLog(dir); got != "list --cask cyfr" {
		t.Errorf("brew ran for a refused --version:\n%s", got)
	}

	s = newProgramScenario(t, "0.9.0", "0.10.0")
	fakeBrew(t, "0.9.0", "0.10.0")
	caskInstalled = restore
	if _, err := s.run(updateOptions{version: "0.10.0"}); err != nil || len(s.handed) != 1 {
		t.Errorf("--version naming the tap's release answered %v, handovers %v", err, s.handed)
	}
}

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
