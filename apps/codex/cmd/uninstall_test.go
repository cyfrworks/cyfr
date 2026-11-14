// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bytes"
	"context"
	"errors"
	"maps"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/cyfr/codex/internal/access"
)

// uninstallDocker stands in for docker: it logs each call and answers the
// project's networks and volumes; an image named in $FAKE_DOCKER_DIR/in-use
// is another container's, and one in absent is not on the machine.
const uninstallDocker = `#!/bin/bash
d="$FAKE_DOCKER_DIR"
printf '%s\n' "$*" >> "$d/log"
case "$1 $2" in
  "network ls") printf 'n1\nn2\n' ;;
  "volume ls") printf 'cyfr_homes\ncyfr_tailscale\n' ;;
  "image rm")
    if grep -qxF "$3" "$d/in-use" 2>/dev/null; then echo "Error response from daemon: conflict: unable to remove repository reference \"$3\" (must force) - container 0123 is using its referenced image" >&2; exit 1; fi
    if grep -qxF "$3" "$d/absent" 2>/dev/null; then echo "Error response from daemon: No such image: $3" >&2; exit 1; fi ;;
esac
exit 0
`

// uninstallScenario is one CYFR's directory as cyfr init leaves it, with
// its data, a person's own files beside them, a home holding the
// program's settings and device key, this program at a path of the
// test's with its link onto PATH, a fake docker and a fake engine, and
// the commands sudo was handed, one per call.
type uninstallScenario struct {
	t               *testing.T
	dir, fake, home string
	self, link      string
	engine          *fakeStack
	root            []string
	// refuseRoot fails the root command that contains it.
	refuseRoot string
	compose    []byte
}

func newUninstallScenario(t *testing.T) *uninstallScenario {
	s := &uninstallScenario{t: t, dir: filepath.Join(t.TempDir(), "my-cyfr"), fake: t.TempDir(), home: t.TempDir(), compose: shippedCompose(t)}
	bin := t.TempDir()
	s.self, s.link = filepath.Join(bin, "cyfr"), filepath.Join(bin, "link", "cyfr")
	files := map[string]string{
		"docker-compose.yml":       string(s.compose),
		"Caddyfile":                "",
		".env":                     "CYFR_ACCESS=local\n",
		".env.example":             "CYFR_ACCESS=\n",
		".env.locus.example":       "",
		"keeper.seccomp.json":      "{}",
		"configuration-guide.md":   "# guide\n",
		"LICENSE":                  "",
		"LICENSES/Apache-2.0.txt":  "",
		"FAIR_SOURCE.md":           "",
		"wit/cyfr/a.wit":           "package cyfr:a;\n",
		".gitignore":               projectGitignore,
		".cyfr/lock":               "",
		"aqua/aqua.md":             "# soul\n",
		"aqua/crew/explorer.md":    "# shipped\n",
		"aqua/skills/web/SKILL.md": "# shipped\n",
		"aqua/crew/mine.md":        "# the person's own crew member\n",
		"aqua/skills/web/mine.md":  "# the person's own, beside a shipped scroll\n",
		"wit/cyfr/mine.wit":        "package mine:own;\n",
		"LICENSES/mine.txt":        "the person's own\n",
		"data/cyfr.db":             "db",
		"backups/x/db":             "db",
		"store/cyfr.db":            "the person's own data root",
		"personal-document.txt":    "not CYFR's",
	}
	for name, data := range files {
		s.write(filepath.Join(s.dir, name), data)
	}
	s.write(filepath.Join(s.home, ".cyfr", "config.json"), "{}")
	s.write(filepath.Join(s.home, ".cyfr", "version-check.json"), "{}")
	s.write(filepath.Join(s.home, ".cyfr", "device", "key.json"), "device key")
	s.write(s.self, "program")
	s.write(filepath.Join(s.fake, "docker"), uninstallDocker)
	if err := os.MkdirAll(filepath.Dir(s.link), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(s.self, s.link); err != nil {
		t.Fatal(err)
	}
	t.Chdir(s.dir)
	t.Setenv("HOME", s.home)
	t.Setenv("PATH", s.fake+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("FAKE_DOCKER_DIR", s.fake)
	s.engine = useFakeEngine(t)

	savedScaffold := uninstallScaffold
	uninstallScaffold = func(string) ([]string, error) { return slices.Clone(shippedNames), nil }
	t.Cleanup(func() { uninstallScaffold = savedScaffold })
	savedSelf, savedCask, savedLink, savedScreen := selfExecutable, caskInstalled, usrLocalLink, screenInstalled
	savedApply, savedForget := machine.apply, machine.forget
	t.Cleanup(func() {
		selfExecutable, caskInstalled, usrLocalLink, screenInstalled = savedSelf, savedCask, savedLink, savedScreen
		machine.apply, machine.forget = savedApply, savedForget
	})
	selfExecutable = func() (string, error) { return s.self, nil }
	caskInstalled = func() bool { return false }
	usrLocalLink = s.link
	screenInstalled = func() bool { return false }
	// Each root command runs here as this account, on the test's own
	// paths; the screen's, which reach the host's systemd, are recorded
	// and never run.
	machine.apply = func(commands []string) error {
		if len(commands) != 1 {
			t.Fatalf("sudo was handed %d commands at once: %q", len(commands), commands)
		}
		c := commands[0]
		s.root = append(s.root, c)
		if s.refuseRoot != "" && strings.Contains(c, s.refuseRoot) {
			return errors.New("sudo: 3 incorrect password attempts")
		}
		if strings.Contains(c, "systemctl") || strings.Contains(c, screenUnit) {
			return nil
		}
		if out, err := exec.Command("sh", "-c", c).CombinedOutput(); err != nil {
			t.Fatalf("%s: %v %s", c, err, out)
		}
		return nil
	}
	machine.forget = func() {}
	return s
}

func (s *uninstallScenario) write(path, data string) {
	s.t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		s.t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(data), 0755); err != nil {
		s.t.Fatal(err)
	}
}

func (s *uninstallScenario) run(yes, deleteData bool) (string, error) {
	s.t.Helper()
	var out bytes.Buffer
	err := runUninstall(context.Background(), &out, yes, deleteData)
	if holder := s.engine.held(); holder != "" {
		s.t.Errorf("the lock is still held, by %s", holder)
	}
	return out.String(), err
}

func (s *uninstallScenario) log() []string {
	data, _ := os.ReadFile(filepath.Join(s.fake, "log"))
	if len(data) == 0 {
		return nil
	}
	return strings.Split(strings.TrimSuffix(string(data), "\n"), "\n")
}

// left is every file left under dir, relative to it, sorted; nil when dir
// is gone.
func left(t *testing.T, dir string) []string {
	t.Helper()
	var files []string
	err := filepath.WalkDir(dir, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if !d.IsDir() {
			rel, _ := filepath.Rel(dir, path)
			files = append(files, filepath.ToSlash(rel))
		}
		return nil
	})
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		t.Fatal(err)
	}
	slices.Sort(files)
	return files
}

func exists(path string) bool {
	_, err := os.Lstat(path)
	return err == nil
}

// shippedNames are the files the scenarios' release scaffold lays down.
var shippedNames = []string{
	"docker-compose.yml", "Caddyfile", ".env.example", ".env.locus.example", "keeper.seccomp.json",
	"configuration-guide.md", "LICENSE", "LICENSES/Apache-2.0.txt", "FAIR_SOURCE.md", "wit/cyfr/a.wit",
	"aqua/aqua.md", "aqua/crew/explorer.md", "aqua/skills/web/SKILL.md",
}

// kept is what an uninstall that keeps the data leaves in the directory:
// the data, the person's own files, beside CYFR's in wit/, LICENSES/ and
// AQUA's folders among them, and the data root they configured.
var kept = []string{
	"LICENSES/mine.txt", "aqua/crew/mine.md", "aqua/skills/web/mine.md", "backups/x/db", "data/cyfr.db",
	"personal-document.txt", "store/cyfr.db", "wit/cyfr/mine.wit",
}

func (s *uninstallScenario) images() []string {
	path := filepath.Join(s.t.TempDir(), "docker-compose.yml")
	s.write(path, string(s.compose))
	return imagesFromCompose(path, []string{buildsProfile, access.ModePublic, access.ModeTailnet})
}

// removalLog is the whole docker log of an uninstall: the stack stopped
// under its lock, its networks and images removed and its volumes listed,
// and, when the data goes, the volumes removed at the end.
func (s *uninstallScenario) removalLog(deleteData bool) []string {
	label := "label=com.docker.compose.project=" + access.ProjectName(s.dir)
	log := []string{"ENGINE lock uninstall", "ENGINE resume", "ENGINE stop uninstall all=true", "network ls -q --filter " + label, "network rm n1 n2"}
	for _, image := range s.images() {
		log = append(log, "image rm "+image)
	}
	log = append(log, "volume ls -q --filter "+label)
	if deleteData {
		log = append(log, "volume rm cyfr_homes cyfr_tailscale")
	}
	return log
}

// An uninstall answered yes once removes the stack, CYFR's own files, the
// link onto PATH as root, the program and its settings, and keeps the
// data, every volume, the device key and every file CYFR did not put
// there.
func TestUninstallRemovesWhatCYFRPutThereAndKeepsTheData(t *testing.T) {
	s := newUninstallScenario(t)
	out, err := s.run(true, false)
	if err != nil {
		t.Fatalf("cyfr uninstall answered %v\n%s", err, out)
	}
	if got := left(t, s.dir); !slices.Equal(got, kept) {
		t.Errorf("the directory holds %q, want %q", got, kept)
	}
	if got := s.log(); !slices.Equal(got, s.removalLog(false)) {
		t.Errorf("docker ran\n%s\nwant\n%s", strings.Join(got, "\n"), strings.Join(s.removalLog(false), "\n"))
	}
	if want := []string{shellQuote([]string{"rm", "-f", "--", s.link})}; !slices.Equal(s.root, want) {
		t.Errorf("sudo ran %q, want %q", s.root, want)
	}
	if got := left(t, s.home); !slices.Equal(got, []string{".cyfr/device/key.json"}) {
		t.Errorf("the home holds %q, want the device key alone", got)
	}
	for _, gone := range []string{s.self, s.link} {
		if exists(gone) {
			t.Errorf("%s is still there", gone)
		}
	}
	for _, line := range []string{
		"It keeps:\n  CYFR's data, unless you say next to delete it: " + filepath.Join(s.dir, "data") + ", " + filepath.Join(s.dir, "backups") + ", the stack's volumes (the programs' kept files among them), " + filepath.Join(s.home, ".cyfr", "device", "key.json") + " (this machine's device key)\n",
		"  every other file in " + s.dir + ", and every link, as it is\n",
		"CYFR's data stays.\n",
		"CYFR is uninstalled. Its data stays: ",
	} {
		if !strings.Contains(out, line) {
			t.Errorf("the output lacks %q:\n%s", line, out)
		}
	}
}

// The data is its own question, asked after the first and read: answered
// no, the uninstall goes on and keeps it; answered yes, the data goes too,
// last, with every volume and the device key, and the person's own files
// stay.
func TestUninstallAsksAboutTheDataApart(t *testing.T) {
	s := newUninstallScenario(t)
	askWith(t, true, strings.NewReader("yes\nno\n"))
	out, err := s.run(false, false)
	if err != nil || !strings.Contains(out, "Uninstall CYFR? (yes/no) [no]: ") || !strings.Contains(out, "Delete CYFR's data too? It cannot be undone. (yes/no) [no]: CYFR's data stays.\n") {
		t.Fatalf("cyfr uninstall answered yes then no answered %v\n%s", err, out)
	}
	if got := left(t, s.dir); !slices.Equal(got, kept) {
		t.Errorf("the directory holds %q, want %q", got, kept)
	}
	if got := s.log(); !slices.Equal(got, s.removalLog(false)) {
		t.Errorf("docker ran\n%s", strings.Join(got, "\n"))
	}

	s = newUninstallScenario(t)
	askWith(t, true, strings.NewReader("yes\nyes\n"))
	out, err = s.run(false, false)
	if err != nil || !strings.HasSuffix(out, "Removed this machine's device key.\nCYFR is uninstalled, its data with it.\n") {
		t.Fatalf("cyfr uninstall answered yes twice answered %v\n%s", err, out)
	}
	if got, want := left(t, s.dir), []string{"LICENSES/mine.txt", "aqua/crew/mine.md", "aqua/skills/web/mine.md", "personal-document.txt", "store/cyfr.db", "wit/cyfr/mine.wit"}; !slices.Equal(got, want) {
		t.Errorf("the directory holds %q, want %q", got, want)
	}
	if got := s.log(); !slices.Equal(got, s.removalLog(true)) {
		t.Errorf("docker ran\n%s", strings.Join(got, "\n"))
	}
	if got := left(t, s.home); len(got) != 0 {
		t.Errorf("the home holds %q", got)
	}
	data := shellQuote([]string{"rm", "-rf", "--", filepath.Join(s.dir, "data"), filepath.Join(s.dir, "backups")})
	if want := []string{shellQuote([]string{"rm", "-f", "--", s.link}), data}; !slices.Equal(s.root, want) {
		t.Errorf("sudo ran %q, want %q", s.root, want)
	}
}

// --yes answers the first question alone: without a terminal the data is
// kept. --delete-data-without-asking answers the second.
func TestUninstallYesKeepsTheDataAndItsOwnFlagDeletesIt(t *testing.T) {
	s := newUninstallScenario(t)
	if _, err := s.run(true, false); err != nil || !exists(filepath.Join(s.dir, "data", "cyfr.db")) {
		t.Fatalf("cyfr uninstall --yes answered %v; the directory holds %q", err, left(t, s.dir))
	}
	s = newUninstallScenario(t)
	if _, err := s.run(true, true); err != nil || exists(filepath.Join(s.dir, "data")) || exists(filepath.Join(s.dir, "backups")) {
		t.Fatalf("cyfr uninstall --yes --delete-data-without-asking answered %v; the directory holds %q", err, left(t, s.dir))
	}
	if got := s.log(); !slices.Equal(got, s.removalLog(true)) {
		t.Errorf("docker ran\n%s", strings.Join(got, "\n"))
	}
}

// Without a terminal and --yes, and answered no, nothing is removed or
// stopped.
func TestUninstallRemovesNothingUnconfirmed(t *testing.T) {
	s := newUninstallScenario(t)
	before := left(t, s.dir)
	_, err := s.run(false, false)
	if err == nil || err.Error() != "Nothing was removed: there is no terminal to confirm the uninstall on. Run it again with --yes to uninstall, or at a terminal" {
		t.Fatalf("cyfr uninstall with no terminal answered %v", err)
	}
	s.nothingRemoved(before)

	askWith(t, true, strings.NewReader("no\n"))
	out, err := s.run(false, false)
	if err != nil || !strings.HasSuffix(out, "Uninstall CYFR? (yes/no) [no]: Nothing was removed.\n") {
		t.Fatalf("cyfr uninstall answered no answered %v\n%s", err, out)
	}
	s.nothingRemoved(before)
}

func (s *uninstallScenario) nothingRemoved(before []string) {
	s.t.Helper()
	if log := s.log(); len(log) != 0 {
		s.t.Errorf("cyfr uninstall ran:\n%s", strings.Join(log, "\n"))
	}
	if len(s.root) != 0 {
		s.t.Errorf("sudo ran %q", s.root)
	}
	if got := left(s.t, s.dir); !slices.Equal(got, before) {
		s.t.Errorf("the directory holds %q, want %q", got, before)
	}
	for _, path := range []string{s.self, s.link, filepath.Join(s.home, ".cyfr", "config.json")} {
		if !exists(path) {
			s.t.Errorf("%s is gone", path)
		}
	}
}

// A project in ~/.cyfr itself keeps its data: the settings are removed as
// the files they are, never the directory with what is in it.
func TestUninstallInTheSettingsDirectoryKeepsTheData(t *testing.T) {
	s := newUninstallScenario(t)
	project := filepath.Join(s.home, ".cyfr")
	for _, name := range []string{"docker-compose.yml", ".env", ".cyfr", "data", "backups", "aqua", "wit"} {
		if err := os.Rename(filepath.Join(s.dir, name), filepath.Join(project, name)); err != nil {
			t.Fatal(err)
		}
	}
	s.dir = project
	t.Chdir(project)
	if _, err := s.run(true, false); err != nil {
		t.Fatal(err)
	}
	if got, want := left(t, project), []string{"aqua/crew/mine.md", "aqua/skills/web/mine.md", "backups/x/db", "data/cyfr.db", "device/key.json", "wit/cyfr/mine.wit"}; !slices.Equal(got, want) {
		t.Errorf("~/.cyfr holds %q, want %q", got, want)
	}
}

// Each root command runs alone, and a failure says what is gone and what
// is still here: before CYFR's files go, 'cyfr up' starts the stack
// again; once the data is going, it is never offered.
func TestUninstallSaysWhatIsGoneWhenAStepFails(t *testing.T) {
	s := newUninstallScenario(t)
	s.refuseRoot = "'-f'"
	_, err := s.run(true, true)
	if err == nil || !strings.HasPrefix(err.Error(), "cyfr uninstall stopped: removing the link "+s.link+" failed (sudo: 3 incorrect password attempts). Already removed: the stack's containers. CYFR's data is still here: ") || !strings.Contains(err.Error(), "so 'cyfr up' starts the stack again.") {
		t.Fatalf("a refused link removal answered %v", err)
	}
	if got := left(t, s.dir); !slices.Contains(got, "docker-compose.yml") || !slices.Contains(got, "data/cyfr.db") {
		t.Errorf("the directory holds %q", got)
	}

	s = newUninstallScenario(t)
	s.refuseRoot = "'-rf'"
	_, err = s.run(true, true)
	if err == nil || !strings.HasPrefix(err.Error(), "cyfr uninstall stopped: removing "+filepath.Join(s.dir, "data")+" and "+filepath.Join(s.dir, "backups")+" as root failed") || strings.Contains(err.Error(), "cyfr up") || !strings.Contains(err.Error(), "Already removed: the stack's containers; the link "+s.link+"; the stack's networks; the stack's images; the files CYFR put in "+s.dir+"; its settings; this program.") {
		t.Fatalf("a refused data removal answered %v", err)
	}
	if log := s.log(); log[len(log)-1] == "volume rm cyfr_homes cyfr_tailscale" {
		t.Error("the volumes were removed after the data's removal failed")
	}
}

// Only a CYFR cyfr init made is uninstalled: a directory with an unrelated
// compose project, or none, is refused with nothing removed.
func TestUninstallRefusesWhatIsNotACYFR(t *testing.T) {
	s := newUninstallScenario(t)
	s.write(filepath.Join(s.dir, ".env"), "OTHER=1\n")
	s.write(filepath.Join(s.dir, "docker-compose.yml"), "services:\n  unrelated:\n    image: busybox:latest\n")
	before := left(t, s.dir)
	_, err := s.run(true, true)
	want := "This directory is not a CYFR that cyfr init made, so nothing was removed: it lacks a compose file, .cyfr/ or a .env that names CYFR_ACCESS. Run 'cyfr uninstall' in CYFR's directory"
	if err == nil || err.Error() != want {
		t.Fatalf("cyfr uninstall answered %v, want %q", err, want)
	}
	s.nothingRemoved(before)

	t.Chdir(t.TempDir())
	if _, err := s.run(true, true); err == nil || err.Error() != want {
		t.Fatalf("cyfr uninstall in an empty directory answered %v", err)
	}
}

// The screen service is given back, one root command at a time; a Homebrew
// install keeps its program for brew; an image another container uses
// stays and is said, and one that is not on the machine is no failure.
func TestUninstallGivesTheScreenBackLeavesBrewAndKeepsAnImageInUse(t *testing.T) {
	s := newUninstallScenario(t)
	screenInstalled = func() bool { return true }
	caskInstalled = func() bool { return true }
	images := s.images()
	s.write(filepath.Join(s.fake, "in-use"), images[0]+"\n")
	s.write(filepath.Join(s.fake, "absent"), images[1]+"\n")
	out, err := s.run(true, false)
	if err != nil {
		t.Fatalf("cyfr uninstall answered %v\n%s", err, out)
	}
	for _, line := range []string{
		"  this machine's screen service, which gives the screen back to its login prompt\n",
		"  this program, which Homebrew installed: remove it with 'brew uninstall --cask cyfr'\n",
		"The image " + images[0] + " stays: another container uses it.\n",
	} {
		if !strings.Contains(out, line) {
			t.Errorf("the output lacks %q:\n%s", line, out)
		}
	}
	if !slices.Equal(s.root, screenOffCommands) {
		t.Errorf("sudo ran %q, want the screen's commands one by one", s.root)
	}
	if !exists(s.self) {
		t.Error("a Homebrew install's program was removed")
	}
}

// An AQUA folder that is a link out of the project is neither read nor
// removed through: nothing behind it changes, its empty folders included,
// and the link stays as it was found.
func TestUninstallLeavesALinkAndWhatIsBehindIt(t *testing.T) {
	s := newUninstallScenario(t)
	outside := t.TempDir()
	s.write(filepath.Join(outside, "aqua.md"), "# soul\n")
	s.write(filepath.Join(outside, "crew", "explorer.md"), "# shipped\n")
	if err := os.MkdirAll(filepath.Join(outside, "skills", "empty"), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.RemoveAll(filepath.Join(s.dir, "aqua")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(s.dir, "aqua")); err != nil {
		t.Fatal(err)
	}
	before := entriesOf(t, outside)
	if _, err := s.run(true, false); err != nil {
		t.Fatal(err)
	}
	if after := entriesOf(t, outside); !maps.Equal(after, before) {
		t.Errorf("what the link leads to changed:\nbefore %v\nafter  %v", before, after)
	}
	if target, err := os.Readlink(filepath.Join(s.dir, "aqua")); err != nil || target != outside {
		t.Errorf("the aqua link is %q (%v), want it as it was, to %s", target, err, outside)
	}
}

// Without the release's list of its files, nothing is named, so nothing
// is removed or stopped.
func TestUninstallRemovesNothingWithoutTheReleasesFileNames(t *testing.T) {
	s := newUninstallScenario(t)
	uninstallScaffold = func(string) ([]string, error) { return nil, errors.New("download: no network") }
	before := left(t, s.dir)
	_, err := s.run(true, true)
	if err == nil || !strings.HasPrefix(err.Error(), "cyfr uninstall could not read which files release ") || !strings.Contains(err.Error(), "shipped (download: no network), so it cannot name them; nothing was removed.") {
		t.Fatalf("cyfr uninstall answered %v", err)
	}
	s.nothingRemoved(before)
}

// entriesOf is every path under dir with its mode and, for a file, its
// bytes, read through no link, so a test sees any change beneath dir.
func entriesOf(t *testing.T, dir string) map[string]string {
	t.Helper()
	entries := map[string]string{}
	err := filepath.WalkDir(dir, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		info, err := os.Lstat(path)
		if err != nil {
			return err
		}
		entry := info.Mode().String()
		if info.Mode().IsRegular() {
			data, err := os.ReadFile(path)
			if err != nil {
				return err
			}
			entry += " " + string(data)
		}
		entries[path] = entry
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return entries
}
