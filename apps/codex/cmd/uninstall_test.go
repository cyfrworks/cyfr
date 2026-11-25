// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bytes"
	"cmp"
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"io/fs"
	"maps"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
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
// program's settings; this program sits at a path of the
// test's with its link onto PATH. root is the commands sudo was handed.
type uninstallScenario struct {
	t                        *testing.T
	dir, down, home, outside string
	self, link               string
	docker, downDocker       *uninstallDocker
	root                     []string
	refuseRoot               string
	// notAdministrator is the account outside the sudo and admin groups;
	// asks is sudo asking a password, whose prompt authErr refuses;
	// authenticated counts the prompts.
	notAdministrator, asks bool
	// notUbuntu is a machine other than Ubuntu 26.04, a Mac among them;
	// noTerminal is no terminal for sudo to ask at.
	notUbuntu, noTerminal bool
	// adminGroup is the administrators\' group the account is in, sudo
	// unless a test names admin, a Mac\'s.
	adminGroup string
	// app is the CYFR app's package installed on this machine.
	app           bool
	authErr       error
	authenticated int
	compose       []byte
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
	savedMachine := machine
	savedOpen, savedTerminal, savedInput := openEngine, askTerminal, askInput
	t.Cleanup(func() {
		selfExecutable, caskInstalled, usrLocalLink, screenInstalled = savedSelf, savedCask, savedLink, savedScreen
		machine = savedMachine
		openEngine, askTerminal, askInput = savedOpen, savedTerminal, savedInput
	})
	machine.installed = func(pkg string) bool { return s.app && pkg == appPackage }
	machine.groups = func(context.Context, string) []string {
		if s.notAdministrator {
			return []string{"users"}
		}
		return []string{"users", cmp.Or(s.adminGroup, "sudo")}
	}
	machine.passwordless = func() bool { return !s.asks }
	machine.supported = func() bool { return !s.notUbuntu }
	machine.terminal = func() bool { return !s.noTerminal }
	machine.authenticate = func() error {
		s.authenticated++
		return s.authErr
	}
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
		case slices.Contains(screenOffCommands, c), c == appRemoval:
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
	return imagesFromCompose(path, []string{access.ModePublic, access.ModeTailnet})
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
// into the folder's data, with the program inside the folder, and with the
// program a link in the folder to one outside it. The program or its link
// stays when the folder holds it or its target, and is named; the settings
// files always stay, and are named.
func TestUninstallStopsAsDownDoesAndRemovesNothingElseFromTheFolder(t *testing.T) {
	for _, place := range []string{"away from the user folder", "at the user folder", "at the user folder through a link", "with ~/.cyfr a link into the folder's data", "with the program inside the folder", "with the program a link in the folder to one outside it"} {
		t.Run(place, func(t *testing.T) {
			s := newUninstallScenario(t)
			home := s.home
			gone := []string{s.self, s.link}
			var stays []string
			root := []string{shellQuote([]string{"rm", "-f", "--", s.link})}
			switch place {
			case "at the user folder", "at the user folder through a link":
				s.both(".cyfr/config.json", "{}")
				s.both(".cyfr/version-check.json", "{}")
				home = s.dir
				if place == "at the user folder through a link" {
					home = filepath.Join(t.TempDir(), "home-link")
					if err := os.Symlink(s.dir, home); err != nil {
						t.Fatal(err)
					}
				}
			case "with ~/.cyfr a link into the folder's data":
				s.both("data/config.json", "{}")
				s.both("data/version-check.json", "{}")
				home = t.TempDir()
				if err := os.Symlink(filepath.Join(s.dir, "data"), filepath.Join(home, ".cyfr")); err != nil {
					t.Fatal(err)
				}
			case "with the program inside the folder":
				s.both("bin/cyfr", "program")
				s.self = filepath.Join(s.dir, "bin", "cyfr")
				if err := os.Remove(s.link); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink(s.self, s.link); err != nil {
					t.Fatal(err)
				}
				stays, gone, root = []string{s.self, s.link}, nil, nil
			case "with the program a link in the folder to one outside it":
				for _, dir := range []string{s.dir, s.down} {
					if err := os.MkdirAll(filepath.Join(dir, "bin"), 0755); err != nil {
						t.Fatal(err)
					}
					if err := os.Symlink(s.self, filepath.Join(dir, "bin", "cyfr")); err != nil {
						t.Fatal(err)
					}
				}
				stays, gone = []string{filepath.Join(s.dir, "bin", "cyfr"), s.self}, []string{s.link}
				selfExecutable = func() (string, error) { return stays[0], nil }
			}
			t.Setenv("HOME", home)
			homeBefore := listing(t, s.home)
			s.runDown()
			out, err := s.run(true)
			if err != nil {
				t.Fatalf("cyfr uninstall answered %v\n%s", err, out)
			}
			if got, want := listing(t, s.dir), listing(t, s.down); !maps.Equal(got, want) {
				t.Errorf("the folder after cyfr uninstall differs from the one after cyfr down:\nuninstall %v\ndown      %v", got, want)
			}
			if got := listing(t, s.home); !maps.Equal(got, homeBefore) {
				t.Errorf("the scenario's home changed:\nbefore %v\nafter  %v", homeBefore, got)
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
					t.Errorf("%s is gone, though the folder holds it or its target", path)
				}
			}
			want := "CYFR is uninstalled. Left as they were:\n  every file in " + s.dir + ", CYFR's data among them\n"
			if place == "with the program inside the folder" {
				want += "  " + s.self + ", " + s.link + ", which resolve into that folder\n"
			} else if place == "with the program a link in the folder to one outside it" {
				want += "  " + stays[0] + ", which resolve into that folder\n"
			}
			var settings []string
			for _, name := range []string{"config.json", "version-check.json"} {
				path := filepath.Join(home, ".cyfr", name)
				if !exists(path) {
					t.Errorf("the settings file %s is gone", path)
				}
				settings = append(settings, path)
			}
			want += "  this program's settings, " + strings.Join(settings, ", ") + "\n"
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

// Its root steps take the machine's one order. An account outside the sudo
// and admin groups is refused before anything is shown or asked, with the
// screen's, the app's and the link's commands as one sudo line for whoever
// administers the machine; a refused password, asked after the question
// and before the stack stops, changes nothing; an accepted one comes after
// the sentence, once, before every root command. The sentence names Ubuntu
// on Ubuntu 26.04 alone, and with no terminal for sudo nothing is
// announced.
func TestUninstallChecksTheAccountAndThePasswordFirst(t *testing.T) {
	t.Run("outside the groups", func(t *testing.T) {
		s := newUninstallScenario(t)
		screenInstalled = func() bool { return true }
		s.notAdministrator, s.app = true, true
		before := listing(t, s.dir)
		out, err := s.run(true)
		if err == nil || err.Error() != "Nothing was changed. Run `cyfr uninstall` again once they have" {
			t.Fatalf("cyfr uninstall answered %v\n%s", err, out)
		}
		want := "Your account, " + currentAccount(t) + ", is not in the sudo or admin group, so CYFR does not run commands as root for it. Whoever administers this machine can run this for you:\n" +
			"  sudo sh -c " + shellQuote([]string{strings.Join(append(slices.Clone(screenOffCommands), appRemoval, linkRemoval()), " &&\n    ")}) + "\n"
		if out != want {
			t.Errorf("cyfr uninstall printed:\n%s\nwant:\n%s", out, want)
		}
		s.nothingRemoved(before)
		if s.authenticated != 0 {
			t.Errorf("sudo asked %d times", s.authenticated)
		}
	})
	t.Run("the password refused", func(t *testing.T) {
		s := newUninstallScenario(t)
		s.asks, s.authErr = true, errors.New("exit status 1")
		plan, _ := s.plan()
		before := listing(t, s.dir)
		out, err := s.run(true)
		if err == nil || err.Error() != "The password was not accepted, so nothing was changed. Run `cyfr uninstall` again to try again" {
			t.Fatalf("cyfr uninstall answered %v\n%s", err, out)
		}
		if want := plan + passwordSentence; out != want || s.authenticated != 1 {
			t.Errorf("sudo asked %d times; printed:\n%s\nwant:\n%s", s.authenticated, out, want)
		}
		s.nothingRemoved(before)
	})
	t.Run("the password accepted", func(t *testing.T) {
		s := newUninstallScenario(t)
		s.asks = true
		plan, removed := s.plan()
		out, err := s.run(true)
		if err != nil {
			t.Fatalf("cyfr uninstall answered %v\n%s", err, out)
		}
		if want := plan + passwordSentence + removed; out != want || s.authenticated != 1 {
			t.Errorf("sudo asked %d times; printed:\n%s\nwant:\n%s", s.authenticated, out, want)
		}
		if !slices.Equal(s.root, []string{linkRemoval()}) {
			t.Errorf("sudo ran %q", s.root)
		}
	})
	// An install.sh install on a Mac has the link onto PATH: sudo's
	// sentence names no system there.
	t.Run("a Mac", func(t *testing.T) {
		s := newUninstallScenario(t)
		s.asks, s.notUbuntu, s.adminGroup = true, true, "admin"
		plan, removed := s.plan()
		out, err := s.run(true)
		if err != nil {
			t.Fatalf("cyfr uninstall answered %v\n%s", err, out)
		}
		want := plan + "This machine will now ask for your password: the one you log in to it with. Nothing shows while you type.\n" + removed
		if out != want || s.authenticated != 1 {
			t.Errorf("sudo asked %d times; printed:\n%s\nwant:\n%s", s.authenticated, out, want)
		}
	})
	// With --yes, no terminal and sudo needing a password, nothing is
	// announced and nothing removed: the uninstall is to run at a terminal.
	t.Run("no terminal", func(t *testing.T) {
		s := newUninstallScenario(t)
		s.asks, s.noTerminal = true, true
		plan, _ := s.plan()
		before := listing(t, s.dir)
		out, err := s.run(true)
		if err == nil || err.Error() != "sudo needs your password and there is no terminal for it to ask at, so nothing was changed. Run `cyfr uninstall` at a terminal" {
			t.Fatalf("cyfr uninstall answered %v\n%s", err, out)
		}
		if out != plan || s.authenticated != 0 {
			t.Errorf("sudo asked %d times; printed:\n%s\nwant:\n%s", s.authenticated, out, plan)
		}
		s.nothingRemoved(before)
	})
}

// plan is what the uninstall shows before it asks, and what a whole run
// of the scenario as made prints after it: each removal, then what is
// left.
func (s *uninstallScenario) plan() (shown, removed string) {
	s.t.Helper()
	s.t.Chdir(s.dir)
	p, err := readUninstallPlan()
	if err != nil {
		s.t.Fatal(err)
	}
	var b strings.Builder
	p.show(&b)
	removed = "Removed the stack's containers.\nRemoved the link " + s.link + ".\nRemoved the stack's networks.\nRemoved the stack's images.\nRemoved this program.\n" +
		p.left([]string{"cyfr_homes", "cyfr_tailscale"})
	return b.String(), removed
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
// screenGivenBack is how `cyfr screen off` and `cyfr uninstall` give the
// screen back, in order: the unit's stop first, the one path that ends the
// screen's session and every process in it (session.sh), then its files,
// and tty1's login prompt last.
var screenGivenBack = []string{
	"{ systemctl disable --now cyfr-screen || true; }",
	"rm -f " + screenUnit,
	"systemctl daemon-reload",
	"systemctl enable --now getty@tty1",
}

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
	if !slices.Equal(s.root, screenGivenBack) {
		t.Errorf("sudo ran %q, want the screen's commands one by one", s.root)
	}
	if !exists(s.self) {
		t.Error("a Homebrew install's program was removed")
	}
}

// A cyfr the package records name as a package's never removes itself,
// reached by its own path or by a link, the app beside it whole or not:
// the uninstall removes what it owns, the link in /usr/local/bin among it,
// and leaves the program, naming the package's tool, and the CYFR app's
// package, which may be its own. Where the records cannot answer both stay
// too, saying why; a file named like the app's code beside a cyfr no
// package installed decides nothing, and that cyfr removes the app's
// package, saying so first.
func TestUninstallLeavesAPackagesProgramToThePackage(t *testing.T) {
	for _, c := range []struct {
		name    string
		byLink  bool
		dpkg    string // "owns", "says no" or "fails"
		appAsar bool
	}{
		{"the package's, by its own path, the app's code gone", false, "owns", false},
		{"the package's, by a link", true, "owns", true},
		{"records that fail", false, "fails", false},
		{"an install script's, an app.asar beside it", false, "says no", true},
	} {
		t.Run(c.name, func(t *testing.T) {
			s := newUninstallScenario(t)
			s.app = true
			switch c.dpkg {
			case "owns":
				standInDpkg(t, map[string]string{s.self: "cyfr-desktop"}, false)
			case "says no":
				standInDpkg(t, nil, false)
			case "fails":
				standInDpkg(t, nil, true)
			}
			code := filepath.Join(filepath.Dir(s.self), "app.asar")
			if c.appAsar {
				s.write(code, "the app")
			}
			runs := s.self
			if c.byLink {
				runs = filepath.Join(t.TempDir(), "cyfr")
				if err := os.Symlink(s.self, runs); err != nil {
					t.Fatal(err)
				}
				selfExecutable = func() (string, error) { return runs, nil }
			}
			out, err := s.run(true)
			if err != nil {
				t.Fatalf("cyfr uninstall answered %v\n%s", err, out)
			}
			var lines []string
			switch c.dpkg {
			case "owns":
				lines = []string{
					"  this program, " + runs + ", which the package cyfr-desktop installed: remove it with the system's package tool ('sudo apt remove cyfr-desktop')\n",
					"  this program's link " + s.link + "\n",
					"  this program, " + runs + ", with the package cyfr-desktop\n",
				}
			case "fails":
				lines = []string{"  this program, " + runs + ", since this system's package records could not tell whether a package installed it (dpkg-query --search " + s.self + ": exit status 2)\n"}
			}
			for _, line := range lines {
				if !strings.Contains(out, line) {
					t.Errorf("the output lacks %q:\n%s", line, out)
				}
			}
			if stays := c.dpkg != "says no"; exists(s.self) != stays || (c.appAsar && !exists(code)) || !exists(runs) && stays {
				t.Errorf("the program stays %v (want %v), its app.asar or its link were removed", exists(s.self), stays)
			}
			if _, err := os.Lstat(s.link); err == nil {
				t.Error("the link cyfr owns stays")
			}
			removes := c.dpkg == "says no"
			if slices.Contains(s.root, appRemoval) != removes || strings.Contains(out, "  the CYFR app, the package cyfr-desktop\n") != removes ||
				strings.Contains(out, "Removed the CYFR app.\n") != removes {
				t.Errorf("the app's package removed: %v, want %v; sudo ran %q:\n%s", slices.Contains(s.root, appRemoval), removes, s.root, out)
			}
		})
	}
}

// The account's device folder, its key and the CYFR it connects to, is
// outside the project folder: the uninstall leaves it and names it, as it
// names every other thing it leaves.
func TestUninstallLeavesAndNamesTheDeviceKey(t *testing.T) {
	s := newUninstallScenario(t)
	device := filepath.Join(s.home, ".cyfr", "device")
	s.write(filepath.Join(device, "holder.json"), "{}")
	out, err := s.run(true)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out, "  this account's device key, "+device+"\n") {
		t.Errorf("the uninstall did not name the device key:\n%s", out)
	}
	if _, err := os.Stat(filepath.Join(device, "holder.json")); err != nil {
		t.Errorf("the device key is gone: %v", err)
	}
}

// appBundleLayout makes, in dir, the CYFR app as this system's packaging
// lays it out, and answers the bundle and the cyfr inside it.
func appBundleLayout(t *testing.T, dir string) (bundle, cyfr string) {
	t.Helper()
	switch runtime.GOOS {
	case "darwin":
		bundle = filepath.Join(dir, "CYFR.app")
		cyfr = filepath.Join(bundle, "Contents", "Resources", "cyfr")
		writeFile(t, filepath.Join(bundle, "Contents", "MacOS", "CYFR"), "the app")
	case "windows":
		bundle, cyfr = dir, filepath.Join(dir, "resources", "cyfr.exe")
		writeFile(t, filepath.Join(bundle, "CYFR.exe"), "the app")
	default:
		bundle, cyfr = dir, filepath.Join(dir, "resources", "cyfr")
		writeFile(t, filepath.Join(bundle, "CYFR"), "the app")
	}
	writeFile(t, cyfr, "the app's cyfr")
	return resolvedPath(t, bundle), resolvedPath(t, cyfr)
}

// The cyfr inside an app's bundle, wherever the bundle lies, is never
// removed alone: removed alone, it breaks the app's signature, as cyfr
// uninstall did on macOS and Windows. It stays, named with its app.
func TestUninstallNeverRemovesTheCyfrInsideAnAppsBundle(t *testing.T) {
	bundle, cyfr := appBundleLayout(t, t.TempDir())
	savedSelf, savedLink, savedCask, savedMachine, savedCyfr := selfExecutable, usrLocalLink, caskInstalled, machine, appCyfr
	t.Cleanup(func() {
		selfExecutable, usrLocalLink, caskInstalled, machine, appCyfr = savedSelf, savedLink, savedCask, savedMachine, savedCyfr
	})
	selfExecutable = func() (string, error) { return cyfr, nil }
	usrLocalLink = filepath.Join(t.TempDir(), "no-link")
	caskInstalled = func() bool { return false }
	elsewhere := filepath.Join(t.TempDir(), "cyfr")
	appCyfr = func() (string, error) { return elsewhere, nil }
	t.Chdir(t.TempDir())
	p, err := readUninstallPlan()
	if err != nil {
		t.Fatal(err)
	}
	if p.self != "" || p.bundled != cyfr {
		t.Fatalf("the plan removes %q and keeps %q as the app's, want %q kept", p.self, p.bundled, cyfr)
	}
	var out strings.Builder
	p.show(&out)
	if want := "  this program, " + cyfr + ", inside the CYFR app at " + bundle + ", which goes with the app alone\n"; !strings.Contains(out.String(), want) {
		t.Errorf("the plan does not say %q:\n%s", want, out.String())
	}
	if strings.Contains(out.String(), "  this program, "+cyfr+"\n") {
		t.Errorf("the plan removes the app's cyfr:\n%s", out.String())
	}
}

// The installed app this system's installer put there: on macOS the
// uninstall removes its bundle whole, this program inside it with it; on
// Windows it names Windows Installer's removal and removes nothing of it.
func TestUninstallRemovesOrNamesTheInstalledApp(t *testing.T) {
	if runtime.GOOS != "darwin" && runtime.GOOS != "windows" {
		t.Skip("the DEB's app is the package tool's (TestUninstallLeavesAPackagesProgramToThePackage)")
	}
	bundle, cyfr := appBundleLayout(t, t.TempDir())
	savedSelf, savedLink, savedCask, savedMachine, savedCyfr := selfExecutable, usrLocalLink, caskInstalled, machine, appCyfr
	t.Cleanup(func() {
		selfExecutable, usrLocalLink, caskInstalled, machine, appCyfr = savedSelf, savedLink, savedCask, savedMachine, savedCyfr
	})
	selfExecutable = func() (string, error) { return cyfr, nil }
	usrLocalLink = filepath.Join(t.TempDir(), "no-link")
	caskInstalled = func() bool { return false }
	appCyfr = func() (string, error) { return cyfr, nil }
	machine.appPresent = func() bool { return true }
	t.Chdir(t.TempDir())
	p, err := readUninstallPlan()
	if err != nil {
		t.Fatal(err)
	}
	var out strings.Builder
	p.show(&out)
	if runtime.GOOS == "darwin" {
		if p.bundle != bundle || p.self != "" || p.msi {
			t.Errorf("the plan removes the bundle %q and the program %q, msi %v; want the bundle %q alone", p.bundle, p.self, p.msi, bundle)
		}
		if want := "  the CYFR app, " + bundle + ", once it is closed, and this program inside it\n"; !strings.Contains(out.String(), want) {
			t.Errorf("the plan does not say %q:\n%s", want, out.String())
		}
		return
	}
	if !p.msi || p.bundle != "" || p.self != "" {
		t.Errorf("the plan names the MSI %v, removes the bundle %q and the program %q", p.msi, p.bundle, p.self)
	}
	if want := "  the CYFR app, which Windows Installer installed, and the cyfr inside it: remove CYFR in Windows' Settings, Apps, Installed apps\n"; !strings.Contains(out.String(), want) {
		t.Errorf("the plan does not say %q:\n%s", want, out.String())
	}
}
