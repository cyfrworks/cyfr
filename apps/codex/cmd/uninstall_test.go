// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bytes"
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"io/fs"
	"maps"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"

	"github.com/cyfr/codex/internal/access"
)

// uninstallDocker stands in for docker inside the test process: it records
// each call, with the project folder written <dir>, and answers the
// project's networks and volumes; an image in inUse is another container's,
// one in absent is not on the machine, and every other call (the engine's
// recovery and stop) is answered with nothing, a daemon with no container
// of the project.
type uninstallDocker struct {
	dir    string
	mu     sync.Mutex
	calls  []string
	inUse  map[string]bool
	absent map[string]bool
}

func (d *uninstallDocker) Run(ctx context.Context, c access.Call) (access.Result, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.calls = append(d.calls, strings.ReplaceAll(strings.Join(c.Args, " "), d.dir, "<dir>"))
	var res access.Result
	switch strings.Join(c.Args[:min(2, len(c.Args))], " ") {
	case "network ls":
		res.Stdout = []byte("n1\nn2\n")
	case "volume ls":
		res.Stdout = []byte("cyfr_homes\ncyfr_tailscale\n")
	case "image rm":
		switch image := c.Args[2]; {
		case d.inUse[image]:
			res.ExitCode, res.Stderr = 1, []byte("Error response from daemon: conflict: unable to remove repository reference \""+image+"\" (must force) - container 0123 is using its referenced image")
		case d.absent[image]:
			res.ExitCode, res.Stderr = 1, []byte("Error response from daemon: No such image: "+image)
		}
	}
	return res, nil
}

// uninstallScenario is two identical CYFR folders, each holding everything
// an install makes, a person's own files and links beside them, record
// files of an older shape, data in each place it may be kept, a leftover
// materialized compose file and an open Serve configuration: cyfr down runs
// in one (down) and cyfr uninstall in the other (dir), each through the
// real engine over a docker of its own in this process. A home holds the
// program's settings and device key; this program sits at a path of the
// test's with its link onto PATH. root is the commands sudo was handed.
type uninstallScenario struct {
	t                        *testing.T
	dir, down, home, outside string
	self, link               string
	docker, downDocker       *uninstallDocker
	root                     []string
	refuseRoot               string
	compose                  []byte
}

// newUninstallScenario builds the scenario. It fails at once unless no sh,
// rm, sudo or docker can be found: PATH is one empty folder of the test's,
// every docker call goes to the in-process fake through the engine, and
// sudo's commands are recorded and applied here, in Go.
func newUninstallScenario(t *testing.T) *uninstallScenario {
	s := &uninstallScenario{t: t, dir: filepath.Join(t.TempDir(), "my-cyfr"), down: filepath.Join(t.TempDir(), "my-cyfr"), home: t.TempDir(), outside: t.TempDir(), compose: shippedCompose(t)}
	t.Setenv("PATH", t.TempDir())
	for _, program := range []string{"sh", "rm", "sudo", "docker"} {
		if found, err := exec.LookPath(program); err == nil {
			t.Fatalf("%s is reachable at %s: no test of the uninstall may run it", program, found)
		}
	}
	bin := t.TempDir()
	s.self, s.link = filepath.Join(bin, "cyfr"), filepath.Join(bin, "link", "cyfr")
	s.write(filepath.Join(s.outside, "target.txt"), "outside")
	s.fill(s.dir)
	s.fill(s.down)
	s.write(filepath.Join(s.home, ".cyfr", "config.json"), "{}")
	s.write(filepath.Join(s.home, ".cyfr", "version-check.json"), "{}")
	s.write(filepath.Join(s.home, ".cyfr", "device", "key.json"), "device key")
	s.write(filepath.Join(s.home, ".cyfr", "other.json"), "not a settings file")
	s.write(s.self, "program")
	if err := os.MkdirAll(filepath.Dir(s.link), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(s.self, s.link); err != nil {
		t.Fatal(err)
	}
	t.Setenv("HOME", s.home)
	s.docker = &uninstallDocker{dir: s.dir, inUse: map[string]bool{}, absent: map[string]bool{}}
	s.downDocker = &uninstallDocker{dir: s.down}

	savedSelf, savedCask, savedLink, savedScreen := selfExecutable, caskInstalled, usrLocalLink, screenInstalled
	savedApply, savedForget := machine.apply, machine.forget
	savedOpen, savedTerminal, savedInput := openEngine, askTerminal, askInput
	t.Cleanup(func() {
		selfExecutable, caskInstalled, usrLocalLink, screenInstalled = savedSelf, savedCask, savedLink, savedScreen
		machine.apply, machine.forget = savedApply, savedForget
		openEngine, askTerminal, askInput = savedOpen, savedTerminal, savedInput
	})
	selfExecutable = func() (string, error) { return s.self, nil }
	caskInstalled = func() bool { return false }
	usrLocalLink = s.link
	screenInstalled = func() bool { return false }
	machine.apply = func(commands []string) error {
		if len(commands) != 1 {
			t.Fatalf("sudo was handed %d commands at once: %q", len(commands), commands)
		}
		c := commands[0]
		s.root = append(s.root, c)
		if s.refuseRoot != "" && strings.Contains(c, s.refuseRoot) {
			return errors.New("sudo: 3 incorrect password attempts")
		}
		switch {
		case c == shellQuote([]string{"rm", "-f", "--", s.link}):
			return os.Remove(s.link)
		case slices.Contains(screenOffCommands, c):
			return nil
		}
		t.Fatalf("sudo was handed %q, which no step of the uninstall runs", c)
		return nil
	}
	machine.forget = func() {}
	askTerminal = func() bool { return false }
	return s
}

// fill makes dir one of the scenario's CYFR folders: the same files, links
// and modes every time.
func (s *uninstallScenario) fill(dir string) {
	s.t.Helper()
	for name, data := range map[string]string{
		"docker-compose.yml":                string(s.compose),
		"Caddyfile":                         "",
		".env":                              "CYFR_ACCESS=local\n",
		".env.example":                      "CYFR_ACCESS=\n",
		".env.locus.example":                "",
		"keeper.seccomp.json":               "{}",
		"configuration-guide.md":            "# guide\n",
		"LICENSE":                           "",
		"LICENSES/Apache-2.0.txt":           "",
		"FAIR_SOURCE.md":                    "",
		"wit/cyfr/a.wit":                    "package cyfr:a;\n",
		"wit/cyfr/mine.wit":                 "package mine:own;\n",
		".gitignore":                        projectGitignore + "# the person's own line\n",
		".cyfr/files.json":                  `{"files": ["data/cyfr.db", "../outside.txt"]}`,
		".cyfr/files":                       "data/cyfr.db\nbackups/x/db\n",
		".cyfr/store/cyfr.db":               "a database kept under .cyfr",
		".cyfr/compose.resolved.orphan.yml": "services: {}\n",
		".cyfr/tailscale-serve/serve.json":  `{"TCP":{"443":{"HTTPS":true}},"Web":{"cyfr:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:4000"}}}}}`,
		"aqua/aqua.md":                      "# soul\n",
		"aqua/crew/mine.md":                 "# the person's own crew member\n",
		"data/cyfr.db":                      "db",
		"backups/x/db":                      "db",
		"store/cyfr.db":                     "the person's own data root",
		"personal-document.txt":             "not CYFR's",
	} {
		s.write(filepath.Join(dir, name), data)
	}
	for name, target := range map[string]string{
		"a-link-to-a-file":   filepath.Join(s.outside, "target.txt"),
		"a-link-to-a-folder": s.outside,
		"a-dangling-link":    filepath.Join(s.outside, "gone"),
		"aqua/skills":        s.outside,
	} {
		if err := os.Symlink(target, filepath.Join(dir, name)); err != nil {
			s.t.Fatal(err)
		}
	}
}

// both writes data at name in each of the two folders.
func (s *uninstallScenario) both(name, data string) {
	s.write(filepath.Join(s.dir, name), data)
	s.write(filepath.Join(s.down, name), data)
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

// runDown is cyfr down in the down folder.
func (s *uninstallScenario) runDown() {
	s.t.Helper()
	s.t.Chdir(s.down)
	openRealEngine(s.downDocker)
	var out bytes.Buffer
	if err := runDown(context.Background(), &out); err != nil {
		s.t.Fatalf("cyfr down answered %v\n%s", err, out.String())
	}
}

// run is cyfr uninstall in the scenario's folder.
func (s *uninstallScenario) run(yes bool) (string, error) {
	s.t.Helper()
	s.t.Chdir(s.dir)
	openRealEngine(s.docker)
	var out bytes.Buffer
	err := runUninstall(context.Background(), &out, yes)
	return out.String(), err
}

// openRealEngine has every command open the access engine itself, over d.
func openRealEngine(d access.Docker) {
	openEngine = func(dir string) (stackEngine, error) {
		e, err := access.Open(dir, d)
		if err != nil {
			return nil, err
		}
		return e, nil
	}
}

// listing is every entry under dir by its path in dir, read through no
// link: its kind, size, every mode bit, owner, a file's content digest and
// a link's target.
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
		entry := fmt.Sprintf("%s %d %s", info.Mode(), info.Size(), fileOwner(info))
		switch {
		case info.Mode().IsRegular():
			data, err := os.ReadFile(path)
			if err != nil {
				return err
			}
			entry += fmt.Sprintf(" sha256:%x", sha256.Sum256(data))
		case info.Mode()&fs.ModeSymlink != 0:
			target, err := os.Readlink(path)
			if err != nil {
				return err
			}
			entry += " -> " + target
		}
		rel, err := filepath.Rel(dir, path)
		if err != nil {
			return err
		}
		entries[rel] = entry
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

// ownCalls are the docker calls the uninstall makes after the stop: its
// networks and images removed, its volumes listed and kept.
func (s *uninstallScenario) ownCalls() []string {
	label := "label=com.docker.compose.project=" + access.ProjectName(s.dir)
	calls := []string{"network ls -q --filter " + label, "network rm n1 n2"}
	for _, image := range s.images() {
		calls = append(calls, "image rm "+image)
	}
	return append(calls, "volume ls -q --filter "+label)
}

// The uninstall stops the stack as cyfr down does and removes nothing else
// from the folder: two identical folders, cyfr down run in one and cyfr
// uninstall in the other, list the same afterwards, entry for entry, and
// the uninstall's docker calls are cyfr down's followed by its own. Away
// from the user folder, at it, at it through a link, with ~/.cyfr a link
// into the folder's data, and with the program inside the folder; what
// resolves into the folder stays and is named.
func TestUninstallStopsAsDownDoesAndRemovesNothingElseFromTheFolder(t *testing.T) {
	for _, place := range []string{"away from the user folder", "at the user folder", "at the user folder through a link", "with ~/.cyfr a link into the folder's data", "with the program inside the folder"} {
		t.Run(place, func(t *testing.T) {
			s := newUninstallScenario(t)
			awayHome := listing(t, s.home)
			gone := []string{filepath.Join(s.home, ".cyfr", "config.json"), filepath.Join(s.home, ".cyfr", "version-check.json"), s.self, s.link}
			var stays []string
			root := []string{shellQuote([]string{"rm", "-f", "--", s.link})}
			switch place {
			case "at the user folder", "at the user folder through a link":
				s.both(".cyfr/config.json", "{}")
				s.both(".cyfr/version-check.json", "{}")
				s.both(".cyfr/device/key.json", "device key")
				home := s.dir
				if place == "at the user folder through a link" {
					home = filepath.Join(t.TempDir(), "home-link")
					if err := os.Symlink(s.dir, home); err != nil {
						t.Fatal(err)
					}
				}
				t.Setenv("HOME", home)
				stays = []string{filepath.Join(home, ".cyfr", "config.json"), filepath.Join(home, ".cyfr", "version-check.json")}
				gone = []string{s.self, s.link}
			case "with ~/.cyfr a link into the folder's data":
				s.both("data/config.json", "{}")
				s.both("data/version-check.json", "{}")
				home := t.TempDir()
				if err := os.Symlink(filepath.Join(s.dir, "data"), filepath.Join(home, ".cyfr")); err != nil {
					t.Fatal(err)
				}
				t.Setenv("HOME", home)
				stays = []string{filepath.Join(home, ".cyfr", "config.json"), filepath.Join(home, ".cyfr", "version-check.json")}
				gone = []string{s.self, s.link}
			case "with the program inside the folder":
				s.both("bin/cyfr", "program")
				s.self = filepath.Join(s.dir, "bin", "cyfr")
				if err := os.Remove(s.link); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink(s.self, s.link); err != nil {
					t.Fatal(err)
				}
				stays = []string{s.self, s.link}
				gone = gone[:2]
				root = nil
			}
			s.runDown()
			out, err := s.run(true)
			if err != nil {
				t.Fatalf("cyfr uninstall answered %v\n%s", err, out)
			}
			if got, want := listing(t, s.dir), listing(t, s.down); !maps.Equal(got, want) {
				t.Errorf("the folder after cyfr uninstall differs from the one after cyfr down:\nuninstall %v\ndown      %v", got, want)
			}
			if want := append(slices.Clone(s.downDocker.calls), s.ownCalls()...); !slices.Equal(s.docker.calls, want) {
				t.Errorf("docker ran\n%s\nwant cyfr down's calls, then the uninstall's own\n%s", strings.Join(s.docker.calls, "\n"), strings.Join(want, "\n"))
			}
			if !slices.Equal(s.root, root) {
				t.Errorf("sudo ran %q, want %q", s.root, root)
			}
			for _, path := range gone {
				if exists(path) {
					t.Errorf("%s is still there", path)
				}
			}
			for _, path := range stays {
				if !exists(path) {
					t.Errorf("%s is gone, though it resolves into the folder", path)
				}
			}
			if place == "away from the user folder" {
				delete(awayHome, filepath.Join(".cyfr", "config.json"))
				delete(awayHome, filepath.Join(".cyfr", "version-check.json"))
				// .cyfr's own size counts its entries, two of which went.
				delete(awayHome, ".cyfr")
				got := listing(t, s.home)
				delete(got, ".cyfr")
				if !maps.Equal(got, awayHome) {
					t.Errorf("the home changed beyond its two settings files:\nwant %v\ngot  %v", awayHome, got)
				}
			}
			want := "CYFR is uninstalled. Left as they were:\n  every file in " + s.dir + ", CYFR's data among them\n"
			if len(stays) > 0 {
				want += "  " + strings.Join(stays, ", ") + ", which resolve into that folder\n"
			}
			if key := filepath.Join(os.Getenv("HOME"), ".cyfr", "device", "key.json"); exists(key) {
				want += "  this machine's device key, " + key + "\n"
			}
			want += "  the stack's volumes, which this command removes:\n    docker volume rm 'cyfr_homes' 'cyfr_tailscale'\n"
			if !strings.HasSuffix(out, want) {
				t.Errorf("cyfr uninstall ended\n%s\nwant it to end\n%s", out, want)
			}
		})
	}
}

// Without a terminal and --yes, and answered no, nothing is stopped or
// removed.
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
	if len(s.docker.calls) != 0 {
		s.t.Errorf("cyfr uninstall ran docker:\n%s", strings.Join(s.docker.calls, "\n"))
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
// compose project is refused with nothing stopped or removed.
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
	s.docker.inUse[images[0]] = true
	s.docker.absent[images[1]] = true
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
