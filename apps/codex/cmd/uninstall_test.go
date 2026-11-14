// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bytes"
	"context"
	"errors"
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
  "volume ls") printf 'v1\n' ;;
  "image rm")
    if grep -qxF "$3" "$d/in-use" 2>/dev/null; then echo "Error response from daemon: conflict: unable to remove repository reference \"$3\" (must force) - container 0123 is using its referenced image" >&2; exit 1; fi
    if grep -qxF "$3" "$d/absent" 2>/dev/null; then echo "Error response from daemon: No such image: $3" >&2; exit 1; fi ;;
esac
exit 0
`

// uninstallScenario is one CYFR's directory beside its data, a home with
// the program's settings, this program at a path of the test's with its
// link onto PATH, a fake docker and a fake engine, and the commands sudo
// was handed.
type uninstallScenario struct {
	t                *testing.T
	dir, fake, home  string
	self, link       string
	engine           *fakeStack
	root             [][]string
	refuseRoot       bool
	compose          []byte
	images, projectN string
}

func newUninstallScenario(t *testing.T) *uninstallScenario {
	s := &uninstallScenario{t: t, dir: filepath.Join(t.TempDir(), "my-cyfr"), fake: t.TempDir(), home: t.TempDir(), compose: shippedCompose(t)}
	bin := t.TempDir()
	s.self, s.link = filepath.Join(bin, "cyfr"), filepath.Join(bin, "link", "cyfr")
	for path, data := range map[string]string{
		filepath.Join(s.dir, "docker-compose.yml"):    string(s.compose),
		filepath.Join(s.dir, ".env"):                  "CYFR_ACCESS=local\n",
		filepath.Join(s.dir, "Caddyfile"):             "",
		filepath.Join(s.dir, "wit", "cyfr", "a.wit"):  "package cyfr:a;\n",
		filepath.Join(s.dir, ".cyfr", "lock"):         "",
		filepath.Join(s.dir, "data", "cyfr.db"):       "db",
		filepath.Join(s.dir, "backups", "x", "db"):    "db",
		filepath.Join(s.home, ".cyfr", "config.json"): "{}",
		s.self:                          "program",
		filepath.Join(s.fake, "docker"): uninstallDocker,
	} {
		if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(data), 0755); err != nil {
			t.Fatal(err)
		}
	}
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
	// The root commands run here as this account, on the test's own
	// paths; the screen's, which reach the host's systemd, are recorded
	// and never run.
	machine.apply = func(commands []string) error {
		s.root = append(s.root, commands)
		if s.refuseRoot {
			return errors.New("sudo: 3 incorrect password attempts")
		}
		for _, c := range commands {
			if strings.Contains(c, "systemctl") || strings.Contains(c, screenUnit) {
				continue
			}
			if out, err := exec.Command("sh", "-c", c).CombinedOutput(); err != nil {
				t.Fatalf("%s: %v %s", c, err, out)
			}
		}
		return nil
	}
	machine.forget = func() {}
	s.projectN = access.ProjectName(s.dir)
	s.images = strings.Join(imagesFromCompose("docker-compose.yml", []string{buildsProfile, access.ModePublic, access.ModeTailnet}), ", ")
	return s
}

func (s *uninstallScenario) run(deleteData, yes bool) (string, error) {
	s.t.Helper()
	var out bytes.Buffer
	err := runUninstall(context.Background(), &out, deleteData, yes)
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

// left are the entries left in the directory, or nil when it is gone.
func (s *uninstallScenario) left() []string {
	entries, err := os.ReadDir(s.dir)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	var names []string
	for _, e := range entries {
		names = append(names, e.Name())
	}
	return names
}

func exists(path string) bool {
	_, err := os.Lstat(path)
	return err == nil
}

// shown is the plan as cyfr uninstall shows it for the scenario.
func (s *uninstallScenario) shown(deleteData bool) string {
	lines := []string{
		"cyfr uninstall removes from this machine:",
		"  the CYFR stack of " + s.dir + ": its containers, networks and volumes, and the images " + s.images,
		"  in " + s.dir + ": .cyfr, .env, Caddyfile, docker-compose.yml, wit",
	}
	if deleteData {
		lines = append(lines, "  CYFR's data, "+filepath.Join(s.dir, "backups"), "  CYFR's data, "+filepath.Join(s.dir, "data"))
	}
	lines = append(lines,
		"  this program, "+s.self+", and its link "+s.link,
		"  its settings, "+filepath.Join(s.home, ".cyfr"),
		"It keeps:")
	if !deleteData {
		lines = append(lines, "  CYFR's data, data/ and backups/ in "+s.dir+" (cyfr uninstall --delete-data removes it too)")
	}
	lines = append(lines, "  Docker, and every package other software uses",
		"These commands run as root, through one sudo, which asks for this machine's password:")
	for _, c := range s.rootCommands(deleteData) {
		lines = append(lines, "  "+c)
	}
	return strings.Join(lines, "\n") + "\n"
}

func (s *uninstallScenario) rootCommands(deleteData bool) []string {
	var commands []string
	if deleteData {
		commands = append(commands, shellQuote([]string{"rm", "-rf", "--", filepath.Join(s.dir, "backups"), filepath.Join(s.dir, "data")}))
	}
	return append(commands, shellQuote([]string{"rm", "-f", "--", s.link}))
}

// removed is the docker log of a whole uninstall: the stack stopped under
// the lock, then its networks, volumes and images removed.
func (s *uninstallScenario) removed() []string {
	label := "label=com.docker.compose.project=" + s.projectN
	log := []string{
		"ENGINE lock uninstall", "ENGINE resume", "ENGINE stop uninstall all=true",
		"network ls -q --filter " + label, "network rm n1 n2",
		"volume ls -q --filter " + label, "volume rm v1",
	}
	for _, image := range strings.Split(s.images, ", ") {
		log = append(log, "image rm "+image)
	}
	return log
}

// An uninstall shows what it removes and keeps, then removes the stack,
// the directory's files but its data, the link onto PATH as root, the
// settings and the program, and keeps the data.
func TestUninstallRemovesTheStackAndTheProgramAndKeepsTheData(t *testing.T) {
	s := newUninstallScenario(t)
	out, err := s.run(false, true)
	want := s.shown(false) + "CYFR is uninstalled. Its data stays in " + s.dir + "; cyfr uninstall --delete-data, or sudo rm -rf " + s.dir + ", removes it.\n"
	if err != nil || out != want {
		t.Fatalf("cyfr uninstall answered %v, printing\n%s\nwant\n%s", err, out, want)
	}
	if got := s.log(); !slices.Equal(got, s.removed()) {
		t.Errorf("docker ran\n%s\nwant\n%s", strings.Join(got, "\n"), strings.Join(s.removed(), "\n"))
	}
	if len(s.root) != 1 || !slices.Equal(s.root[0], s.rootCommands(false)) {
		t.Errorf("sudo ran %q", s.root)
	}
	if got := s.left(); !slices.Equal(got, []string{"backups", "data"}) {
		t.Errorf("the directory holds %q, want its data alone", got)
	}
	for _, gone := range []string{s.self, s.link, filepath.Join(s.home, ".cyfr")} {
		if exists(gone) {
			t.Errorf("%s is still there", gone)
		}
	}
}

// --delete-data removes data/ and backups/ as root, and the directory with
// them.
func TestUninstallDeletesTheDataWhenAsked(t *testing.T) {
	s := newUninstallScenario(t)
	out, err := s.run(true, true)
	want := s.shown(true) + "CYFR is uninstalled, its data with it.\n"
	if err != nil || out != want {
		t.Fatalf("cyfr uninstall --delete-data answered %v, printing\n%s\nwant\n%s", err, out, want)
	}
	if len(s.root) != 1 || !slices.Equal(s.root[0], s.rootCommands(true)) {
		t.Errorf("sudo ran %q", s.root)
	}
	if exists(s.dir) {
		t.Errorf("the directory is still there, holding %q", s.left())
	}
}

// Without a terminal and --yes, and answered no, the plan is shown and
// nothing is removed or stopped.
func TestUninstallRemovesNothingUnconfirmed(t *testing.T) {
	s := newUninstallScenario(t)
	out, err := s.run(false, false)
	if err == nil || err.Error() != "Nothing was removed: there is no terminal to confirm the uninstall on. Run it again with --yes to uninstall, or at a terminal" || out != s.shown(false) {
		t.Fatalf("cyfr uninstall with no terminal answered %v, printing\n%s", err, out)
	}
	s.nothingRemoved()

	askWith(t, true, strings.NewReader("no\n"))
	out, err = s.run(false, false)
	if err != nil || out != s.shown(false)+"Uninstall CYFR? (yes/no) [no]: Nothing was removed.\n" {
		t.Fatalf("cyfr uninstall answered no answered %v, printing\n%s", err, out)
	}
	s.nothingRemoved()
}

func (s *uninstallScenario) nothingRemoved() {
	s.t.Helper()
	if log := s.log(); len(log) != 0 {
		s.t.Errorf("cyfr uninstall ran:\n%s", strings.Join(log, "\n"))
	}
	if len(s.root) != 0 {
		s.t.Errorf("sudo ran %q", s.root)
	}
	s.everythingStays()
}

func (s *uninstallScenario) everythingStays() {
	s.t.Helper()
	if got := s.left(); !slices.Equal(got, []string{".cyfr", ".env", "Caddyfile", "backups", "data", "docker-compose.yml", "wit"}) {
		s.t.Errorf("the directory holds %q", got)
	}
	for _, kept := range []string{s.self, s.link, filepath.Join(s.home, ".cyfr", "config.json")} {
		if !exists(kept) {
			s.t.Errorf("%s is gone", kept)
		}
	}
}

// A refused sudo removes nothing: the stack is stopped, and 'cyfr up'
// starts it again.
func TestUninstallRemovesNothingWhenSudoIsRefused(t *testing.T) {
	s := newUninstallScenario(t)
	s.refuseRoot = true
	_, err := s.run(true, true)
	if err == nil || err.Error() != "The commands as root did not run, so nothing was removed; the stack is stopped, and 'cyfr up' starts it again" {
		t.Fatalf("cyfr uninstall answered %v", err)
	}
	if got := s.log(); !slices.Equal(got, s.removed()[:3]) {
		t.Errorf("docker ran\n%s", strings.Join(got, "\n"))
	}
	s.everythingStays()
}

// Outside CYFR's directory nothing is removed.
func TestUninstallRefusesADirectoryWithoutACompose(t *testing.T) {
	s := newUninstallScenario(t)
	t.Chdir(t.TempDir())
	_, err := s.run(false, true)
	want := "There is no CYFR in this directory, so nothing was removed: it holds no compose file (" + strings.Join(access.ComposeMainFiles, ", ") + "). Run 'cyfr uninstall' in CYFR's directory, the one that holds its docker-compose.yml"
	if err == nil || err.Error() != want {
		t.Fatalf("cyfr uninstall answered %v, want %q", err, want)
	}
	t.Chdir(s.dir)
	s.nothingRemoved()
}

// The screen service goes first among the root commands; a Homebrew
// install keeps its program for brew; an image another container uses
// stays and is said, and one that is not on the machine is no failure.
func TestUninstallGivesTheScreenBackLeavesBrewAndKeepsAnImageInUse(t *testing.T) {
	s := newUninstallScenario(t)
	screenInstalled = func() bool { return true }
	caskInstalled = func() bool { return true }
	images := strings.Split(s.images, ", ")
	if err := os.WriteFile(filepath.Join(s.fake, "in-use"), []byte(images[0]+"\n"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(s.fake, "absent"), []byte(images[1]+"\n"), 0644); err != nil {
		t.Fatal(err)
	}
	out, err := s.run(false, true)
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
	if strings.Contains(out, "this program, "+s.self) {
		t.Errorf("a Homebrew install's program is in the list:\n%s", out)
	}
	if len(s.root) != 1 || !slices.Equal(s.root[0], screenOffCommands) {
		t.Errorf("sudo ran %q, want the screen's commands alone", s.root)
	}
	if !exists(s.self) {
		t.Error("a Homebrew install's program was removed")
	}
}
