// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io/fs"
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

// uninstallScenario is one CYFR's folder holding everything an install
// makes, a person's own files and links beside them, a record file of an
// older shape and data in each place it may be kept; a home holding the
// program's settings and device key; this program at a path of the test's
// with its link onto PATH; a fake docker and a fake engine; and the
// commands sudo was handed, one per call.
type uninstallScenario struct {
	t               *testing.T
	dir, fake, home string
	self, link      string
	engine          *fakeStack
	root            []string
	refuseRoot      string
	compose         []byte
}

func newUninstallScenario(t *testing.T) *uninstallScenario {
	s := &uninstallScenario{t: t, dir: filepath.Join(t.TempDir(), "my-cyfr"), fake: t.TempDir(), home: t.TempDir(), compose: shippedCompose(t)}
	bin := t.TempDir()
	s.self, s.link = filepath.Join(bin, "cyfr"), filepath.Join(bin, "link", "cyfr")
	outside := t.TempDir()
	s.write(filepath.Join(outside, "target.txt"), "outside")
	for name, data := range map[string]string{
		"docker-compose.yml":      string(s.compose),
		"Caddyfile":               "",
		".env":                    "CYFR_ACCESS=local\n",
		".env.example":            "CYFR_ACCESS=\n",
		".env.locus.example":      "",
		"keeper.seccomp.json":     "{}",
		"configuration-guide.md":  "# guide\n",
		"LICENSE":                 "",
		"LICENSES/Apache-2.0.txt": "",
		"FAIR_SOURCE.md":          "",
		"wit/cyfr/a.wit":          "package cyfr:a;\n",
		"wit/cyfr/mine.wit":       "package mine:own;\n",
		".gitignore":              projectGitignore + "# the person's own line\n",
		".cyfr/lock":              "",
		".cyfr/files.json":        `{"files": ["data/cyfr.db", "../outside.txt"]}`,
		".cyfr/files":             "data/cyfr.db\nbackups/x/db\n",
		".cyfr/store/cyfr.db":     "a database kept under .cyfr",
		"aqua/aqua.md":            "# soul\n",
		"aqua/crew/mine.md":       "# the person's own crew member\n",
		"data/cyfr.db":            "db",
		"backups/x/db":            "db",
		"store/cyfr.db":           "the person's own data root",
		"personal-document.txt":   "not CYFR's",
	} {
		s.write(filepath.Join(s.dir, name), data)
	}
	for name, target := range map[string]string{
		"a-link-to-a-file":   filepath.Join(outside, "target.txt"),
		"a-link-to-a-folder": outside,
		"a-dangling-link":    filepath.Join(outside, "gone"),
		"aqua/skills":        outside,
	} {
		if err := os.Symlink(target, filepath.Join(s.dir, name)); err != nil {
			t.Fatal(err)
		}
	}
	s.write(filepath.Join(s.home, ".cyfr", "config.json"), "{}")
	s.write(filepath.Join(s.home, ".cyfr", "version-check.json"), "{}")
	s.write(filepath.Join(s.home, ".cyfr", "device", "key.json"), "device key")
	s.write(s.self, "program")
	s.write(filepath.Join(s.fake, "docker"), uninstallDocker)
	if err := os.Chmod(filepath.Join(s.fake, "docker"), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(s.link), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(s.self, s.link); err != nil {
		t.Fatal(err)
	}
	t.Chdir(s.dir)
	t.Setenv("HOME", s.home)
	t.Setenv("SUDO_USER", "")
	t.Setenv("PATH", s.fake+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("FAKE_DOCKER_DIR", s.fake)
	// Every docker call must reach the fake: the uninstall removes images
	// and networks, and the host's own docker must never see them.
	if found, err := exec.LookPath("docker"); err != nil || found != filepath.Join(s.fake, "docker") {
		t.Fatalf("docker on PATH is %q (%v), not the scenario's fake", found, err)
	}
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
	// Each root command runs here as this account; the screen's, which
	// reach the host's systemd, are recorded and never run.
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
	if err := os.WriteFile(path, []byte(data), 0644); err != nil {
		s.t.Fatal(err)
	}
}

func (s *uninstallScenario) run(yes bool) (string, error) {
	s.t.Helper()
	var out bytes.Buffer
	err := runUninstall(context.Background(), &out, yes)
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

// listing is every entry under dir, read through no link: its name, kind,
// size (a file's or a link's), mode and, for a link, its target.
func listing(t *testing.T, dir string) map[string]string {
	t.Helper()
	entries := map[string]string{}
	err := filepath.WalkDir(dir, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		info, err := os.Lstat(path)
		if err != nil {
			return err
		}
		// A directory's own size counts its entries, which the settings'
		// removal changes in .cyfr; its entries are compared one by one.
		size := info.Size()
		if info.IsDir() {
			size = 0
		}
		entry := fmt.Sprintf("%s %d %v", info.Mode().Type(), size, info.Mode().Perm())
		if info.Mode()&fs.ModeSymlink != 0 {
			target, err := os.Readlink(path)
			if err != nil {
				return err
			}
			entry += " -> " + target
		}
		entries[path] = entry
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return entries
}

func exists(path string) bool {
	_, err := os.Lstat(path)
	return err == nil
}

func (s *uninstallScenario) images() []string {
	path := filepath.Join(s.t.TempDir(), "docker-compose.yml")
	s.write(path, string(s.compose))
	return imagesFromCompose(path, []string{buildsProfile, access.ModePublic, access.ModeTailnet})
}

// removalLog is the docker log of an uninstall: the stack stopped under
// its lock, its networks and images removed, its volumes listed and kept.
func (s *uninstallScenario) removalLog() []string {
	label := "label=com.docker.compose.project=" + access.ProjectName(s.dir)
	log := []string{"ENGINE lock uninstall", "ENGINE resume", "ENGINE stop uninstall all=true", "network ls -q --filter " + label, "network rm n1 n2"}
	for _, image := range s.images() {
		log = append(log, "image rm "+image)
	}
	return append(log, "volume ls -q --filter "+label)
}

// moveHomeInto makes the project folder the home folder: the settings and
// the device key in the project's own .cyfr.
func (s *uninstallScenario) moveHomeInto() {
	s.t.Helper()
	for _, name := range []string{"config.json", "version-check.json", "device/key.json"} {
		data, err := os.ReadFile(filepath.Join(s.home, ".cyfr", name))
		if err != nil {
			s.t.Fatal(err)
		}
		s.write(filepath.Join(s.dir, ".cyfr", name), string(data))
	}
	s.home = s.dir
}

// The uninstall deletes no file in the person's folder: with the project
// away from home, at the home folder, and at the home folder reached
// through a link, the folder's whole listing is as it was, save the two
// settings files by their names when the home's .cyfr is the project's;
// the volumes are listed and kept, and the device key stays.
func TestUninstallDeletesNoFileInTheFolder(t *testing.T) {
	for _, place := range []string{"away from home", "at the home folder", "at the home folder through a link"} {
		t.Run(place, func(t *testing.T) {
			s := newUninstallScenario(t)
			var settings []string
			if place != "away from home" {
				s.moveHomeInto()
				settings = []string{filepath.Join(s.dir, ".cyfr", "config.json"), filepath.Join(s.dir, ".cyfr", "version-check.json")}
				home := s.dir
				if place == "at the home folder through a link" {
					home = filepath.Join(t.TempDir(), "home-link")
					if err := os.Symlink(s.dir, home); err != nil {
						t.Fatal(err)
					}
				}
				t.Setenv("HOME", home)
			}
			want := listing(t, s.dir)
			for _, path := range settings {
				delete(want, path)
			}
			homeBefore := listing(t, s.home)
			out, err := s.run(true)
			if err != nil {
				t.Fatalf("cyfr uninstall answered %v\n%s", err, out)
			}
			if got := listing(t, s.dir); !maps.Equal(got, want) {
				t.Errorf("the folder changed:\nbefore %v\nafter  %v", want, got)
			}
			if got := s.log(); !slices.Equal(got, s.removalLog()) {
				t.Errorf("docker ran\n%s\nwant\n%s", strings.Join(got, "\n"), strings.Join(s.removalLog(), "\n"))
			}
			if place == "away from home" {
				delete(homeBefore, filepath.Join(s.home, ".cyfr", "config.json"))
				delete(homeBefore, filepath.Join(s.home, ".cyfr", "version-check.json"))
				if got := listing(t, s.home); !maps.Equal(got, homeBefore) {
					t.Errorf("the home changed beyond its two settings files:\nwant %v\ngot  %v", homeBefore, got)
				}
			}
			for _, gone := range []string{s.self, s.link} {
				if exists(gone) {
					t.Errorf("%s is still there", gone)
				}
			}
		})
	}
}

// The closing sentence names what is left and the commands that remove it:
// the folder away from home; at the home folder, the entries CYFR's install
// made there and never the folder; the volumes by name; the device key.
func TestUninstallNamesWhatIsLeftAndNeverTheHomeFolder(t *testing.T) {
	s := newUninstallScenario(t)
	out, err := s.run(true)
	key := filepath.Join(s.home, ".cyfr", "device", "key.json")
	want := "CYFR is uninstalled. Left as they were, with the commands that remove them by hand:\n" +
		"  the folder " + s.dir + ", CYFR's data in it:\n    sudo rm -rf -- '" + s.dir + "'\n" +
		"  the stack's volumes:\n    docker volume rm 'cyfr_homes' 'cyfr_tailscale'\n" +
		"  this machine's device key:\n    rm -- '" + key + "'\n"
	if err != nil || !strings.HasSuffix(out, want) {
		t.Fatalf("cyfr uninstall answered %v, ending\n%s\nwant it to end\n%s", err, out, want)
	}

	s = newUninstallScenario(t)
	s.moveHomeInto()
	t.Setenv("HOME", s.dir)
	out, err = s.run(true)
	key = filepath.Join(s.dir, ".cyfr", "device", "key.json")
	entries := "'configuration-guide.md' 'keeper.seccomp.json' 'docker-compose.yml' 'Caddyfile' '.env' '.env.example' '.env.locus.example' '.gitignore' 'LICENSE' 'LICENSES' 'FAIR_SOURCE.md' 'wit' 'aqua' '.cyfr' 'data' 'backups'"
	want = "CYFR is uninstalled. Left as they were, with the commands that remove them by hand:\n" +
		"  the entries CYFR's install made in " + s.dir + ", CYFR's data among them:\n    cd '" + s.dir + "' && sudo rm -rf -- " + entries + "\n" +
		"  the stack's volumes:\n    docker volume rm 'cyfr_homes' 'cyfr_tailscale'\n" +
		"  this machine's device key:\n    rm -- '" + key + "'\n"
	if err != nil || !strings.HasSuffix(out, want) {
		t.Fatalf("cyfr uninstall at the home folder answered %v, ending\n%s\nwant it to end\n%s", err, out, want)
	}
	if strings.Contains(out, "rm -rf -- '"+s.dir+"'") {
		t.Errorf("a command removes the home folder:\n%s", out)
	}
}

// The settings are removed by their exact names, never by a walk of
// ~/.cyfr: at the home folder, where ~/.cyfr is the project's .cyfr, the
// device key and every other file beside them stay.
func TestUninstallRemovesTheSettingsByNameAlone(t *testing.T) {
	s := newUninstallScenario(t)
	s.moveHomeInto()
	t.Setenv("HOME", s.dir)
	if _, err := s.run(true); err != nil {
		t.Fatal(err)
	}
	for _, gone := range []string{"config.json", "version-check.json"} {
		if exists(filepath.Join(s.dir, ".cyfr", gone)) {
			t.Errorf(".cyfr/%s is still there", gone)
		}
	}
	for _, kept := range []string{"device/key.json", "lock", "files.json", "files", "store/cyfr.db"} {
		if !exists(filepath.Join(s.dir, ".cyfr", kept)) {
			t.Errorf(".cyfr/%s is gone", kept)
		}
	}
}

// Without a terminal and --yes, and answered no, nothing is removed or
// stopped.
func TestUninstallRemovesNothingUnconfirmed(t *testing.T) {
	s := newUninstallScenario(t)
	before := listing(t, s.dir)
	_, err := s.run(false)
	if err == nil || err.Error() != "Nothing was removed: there is no terminal to confirm the uninstall on. Run it again with --yes to uninstall, or at a terminal" {
		t.Fatalf("cyfr uninstall with no terminal answered %v", err)
	}
	s.nothingRemoved(before)

	askWith(t, true, strings.NewReader("no\n"))
	out, err := s.run(false)
	if err != nil || !strings.HasSuffix(out, "Uninstall CYFR? (yes/no) [no]: Nothing was removed.\n") {
		t.Fatalf("cyfr uninstall answered no answered %v\n%s", err, out)
	}
	s.nothingRemoved(before)
}

func (s *uninstallScenario) nothingRemoved(before map[string]string) {
	s.t.Helper()
	if log := s.log(); len(log) != 0 {
		s.t.Errorf("cyfr uninstall ran:\n%s", strings.Join(log, "\n"))
	}
	if len(s.root) != 0 {
		s.t.Errorf("sudo ran %q", s.root)
	}
	if got := listing(s.t, s.dir); !maps.Equal(got, before) {
		s.t.Errorf("the folder changed:\nbefore %v\nafter  %v", before, got)
	}
	for _, path := range []string{s.self, s.link, filepath.Join(s.home, ".cyfr", "config.json")} {
		if !exists(path) {
			s.t.Errorf("%s is gone", path)
		}
	}
}

// A failure says what is gone and what is still here.
func TestUninstallSaysWhatIsGoneWhenAStepFails(t *testing.T) {
	s := newUninstallScenario(t)
	s.refuseRoot = "'-f'"
	_, err := s.run(true)
	want := "cyfr uninstall stopped: removing the link " + s.link + " failed (sudo: 3 incorrect password attempts). Already removed: the stack's containers. Every file in " + s.dir + " is still here, so 'cyfr up' starts the stack again. Run 'cyfr uninstall' again to finish."
	if err == nil || err.Error() != want {
		t.Fatalf("a refused link removal answered %v, want %q", err, want)
	}
	if !exists(s.self) || !exists(filepath.Join(s.home, ".cyfr", "config.json")) {
		t.Error("the program or its settings went after the failure")
	}
}

// Only a CYFR cyfr init made is uninstalled: a directory with an unrelated
// compose project, or none, is refused with nothing removed.
func TestUninstallRefusesWhatIsNotACYFR(t *testing.T) {
	s := newUninstallScenario(t)
	s.write(filepath.Join(s.dir, ".env"), "OTHER=1\n")
	before := listing(t, s.dir)
	_, err := s.run(true)
	want := "This directory is not a CYFR that cyfr init made, so nothing was removed: it lacks a compose file, .cyfr/ or a .env that names CYFR_ACCESS. Run 'cyfr uninstall' in CYFR's directory"
	if err == nil || err.Error() != want {
		t.Fatalf("cyfr uninstall answered %v, want %q", err, want)
	}
	s.nothingRemoved(before)
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
	out, err := s.run(true)
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
