// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"cmp"
	"crypto/sha256"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"testing"

	"github.com/cyfr/codex/internal/version"
)

// standIn is a machine for prepareMachine, a fresh Ubuntu 26.04 unless a
// test says otherwise, run by an administrator whose sudo asks for a
// password, recording what it applied. prompt, when set, is called where
// sudo would show its own password prompt.
type standIn struct {
	supported, running, reachableAfter bool
	reachable, displayManager          bool
	passwordless, noTerminal           bool
	arch, system                       string
	installed, member, process         []string
	administrator                      []string
	applied                            [][]string
	applyErr, authErr                  error
	authenticated, forgotten           int
	prompt                             func()
}

// standInMachine stands s in for the machine until t ends. It fails at
// once unless no sh, rm, sudo or docker can be found: PATH is one empty
// folder of the test's, where a test puts its own stand-ins (fakeSudo).
func standInMachine(t *testing.T) *standIn {
	t.Helper()
	t.Setenv("PATH", t.TempDir())
	for _, program := range []string{"sh", "rm", "sudo", "docker"} {
		if found, err := exec.LookPath(program); err == nil {
			t.Fatalf("%s is reachable at %s: no test of the machine may run it", program, found)
		}
	}
	// The CYFR app of this cyfr's version is installed, unless a test says
	// otherwise, so `cyfr screen on` fetches nothing.
	s := &standIn{supported: true, arch: "amd64", system: "linux", administrator: []string{"sudo"},
		installed: []string{appPackage + "=" + version.Version}}
	saved, savedTerminal, savedInput, savedSg := machine, askTerminal, askInput, sgProgram
	t.Cleanup(func() { machine, askTerminal, askInput, sgProgram = saved, savedTerminal, savedInput, savedSg })
	// No test reaches the real sg, which would run this test binary again.
	sgProgram = "/bin/false"
	askTerminal = func() bool { return true }
	askInput = strings.NewReader("yes\n")
	machine.supported = func() bool { return s.supported }
	machine.arch = func() string { return s.arch }
	machine.reachable = func() bool { return s.reachable }
	// An entry pkg=version holds pkg at that version, and pkg alone at 1.
	machine.installed = func(pkg string) string {
		for _, entry := range s.installed {
			if name, at, versioned := strings.Cut(entry, "="); name == pkg {
				if versioned {
					return at
				}
				return "1"
			}
		}
		return ""
	}
	machine.running = func() bool { return s.running }
	machine.displayManager = func() bool { return s.displayManager }
	machine.system = func() string { return s.system }
	machine.groups = func(account string) []string {
		if account == "" {
			return s.process
		}
		return append(slices.Clone(s.member), s.administrator...)
	}
	machine.passwordless = func() bool { return s.passwordless }
	machine.terminal = func() bool { return !s.noTerminal }
	machine.authenticate = func() error {
		s.authenticated++
		if s.prompt != nil {
			s.prompt()
		}
		return s.authErr
	}
	machine.apply = func(commands []string) error {
		s.applied = append(s.applied, commands)
		if slices.ContainsFunc(commands, func(c string) bool { return strings.HasPrefix(c, "usermod") }) {
			s.member = append(s.member, dockerGroup)
		}
		s.reachable = s.reachableAfter
		return s.applyErr
	}
	machine.forget = func() { s.forgotten++ }
	return s
}

// initProjectOnScreen makes the working directory a new project for cyfr
// init, with a compose file and the fake engine, on a machine that can
// show CYFR, at a terminal, whose Docker answers this account.
func initProjectOnScreen(t *testing.T) (*standIn, *fakeStack) {
	t.Helper()
	dir, err := filepath.EvalSymlinks(newInitProject(t))
	if err != nil {
		t.Fatal(err)
	}
	t.Chdir(dir)
	if err := os.WriteFile("docker-compose.yml", []byte("services: {}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	engine := useFakeEngine(t)
	s := standInMachine(t)
	s.reachable = true
	return s, engine
}

// fakeSudoRecord marks a run of this test binary as the sudo fakeSudo put
// on PATH: it appends its arguments, as one line, to the file the variable
// names and runs nothing. -k answers 0, -n 1 (a password is needed), -v
// fakeSudoVerdict's status, and a command 1.
const (
	fakeSudoRecord  = "CYFR_CMD_TEST_FAKE_SUDO"
	fakeSudoVerdict = "CYFR_CMD_TEST_FAKE_SUDO_VERDICT"
)

// fakeSgRecord marks a run of this test binary as the sg sgStandIn names:
// it writes its arguments, one a line, to the file the variable names,
// runs nothing, and exits with fakeSgStatus.
const (
	fakeSgRecord = "CYFR_CMD_TEST_FAKE_SG"
	fakeSgStatus = "CYFR_CMD_TEST_FAKE_SG_STATUS"
)

// fakeDockerAnswers marks a run of this test binary as the docker
// dockerStandIn put on PATH: it answers from FAKE_DOCKER_DIR as the update
// scenario's fakeDocker does, a call's <key>.out on stdout, <key>.err on
// stderr and <key>.exit its status, its argv appended to log, and runs
// nothing.
const fakeDockerAnswers = "CYFR_CMD_TEST_FAKE_DOCKER"

// fakeRecord marks a run of this test binary as a curl or an sh a test put
// on PATH only to see that nothing runs it: it appends its name and
// arguments, as one line, to the file the variable names, and runs nothing.
const fakeRecord = "CYFR_CMD_TEST_FAKE_RECORD"

// fakeBrewDir marks a run of this test binary as the brew fakeBrew put on
// PATH, its state in the folder the variable names (runFakeBrew).
const fakeBrewDir = "CYFR_CMD_TEST_FAKE_BREW"

// runStandIn is this test binary run as the stand-in its name says, sudo,
// sg, docker, brew, curl or sh, when the test that started it set that
// stand-in's record; ok is false for any other run.
func runStandIn() (status int, ok bool) {
	switch name := filepath.Base(os.Args[0]); {
	case (name == "curl" || name == "sh") && os.Getenv(fakeRecord) != "":
		f, err := os.OpenFile(os.Getenv(fakeRecord), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
		if err != nil {
			return 3, true
		}
		_, err = f.WriteString(strings.Join(os.Args, " ") + "\n")
		if f.Close() != nil || err != nil {
			return 3, true
		}
		return 0, true
	case name == "brew" && os.Getenv(fakeBrewDir) != "":
		return runFakeBrew(os.Getenv(fakeBrewDir), strings.Join(os.Args[1:], " ")), true
	case name == "docker" && os.Getenv(fakeDockerAnswers) != "":
		return runFakeDocker(os.Getenv("FAKE_DOCKER_DIR"), os.Args[1:]), true
	case name == "sudo" && os.Getenv(fakeSudoRecord) != "":
		return runFakeSudo(os.Getenv(fakeSudoRecord)), true
	case name == "sg" && os.Getenv(fakeSgRecord) != "":
		var lines strings.Builder
		for _, a := range os.Args[1:] {
			lines.WriteString(a + "\n")
		}
		if os.WriteFile(os.Getenv(fakeSgRecord), []byte(lines.String()), 0o600) != nil {
			return 3, true
		}
		status, err := strconv.Atoi(os.Getenv(fakeSgStatus))
		if err != nil {
			return 3, true
		}
		return status, true
	}
	return 0, false
}

// runFakeBrew records each run in dir's log, answers --prefix with dir,
// `list --cask cyfr` as installed and `list --cask --versions cyfr` with
// dir's version file, which `upgrade --cask cyfr` sets to dir's upgrade-to
// file; `update` succeeds and anything else fails.
func runFakeBrew(dir, args string) int {
	f, err := os.OpenFile(filepath.Join(dir, "log"), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return 3
	}
	_, err = f.WriteString(args + "\n")
	if f.Close() != nil || err != nil {
		return 3
	}
	switch args {
	case "--prefix":
		fmt.Println(dir)
	case "list --cask --versions cyfr":
		v, err := os.ReadFile(filepath.Join(dir, "version"))
		if err != nil {
			return 3
		}
		fmt.Println("cyfr " + strings.TrimSpace(string(v)))
	case "list --cask cyfr", "update":
	case "upgrade --cask cyfr":
		to, err := os.ReadFile(filepath.Join(dir, "upgrade-to"))
		if err != nil || os.WriteFile(filepath.Join(dir, "version"), to, 0o644) != nil {
			return 3
		}
	default:
		return 1
	}
	return 0
}

// runFakeDocker answers args from dir: a compose call by its subcommand
// (exec as rpc, stop as stop-<service>, run as eval), any other by its
// first word (ps as cyfrps, exec as schema).
func runFakeDocker(dir string, args []string) int {
	f, err := os.OpenFile(filepath.Join(dir, "log"), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return 3
	}
	_, err = f.WriteString(strings.Join(args, " ") + "\n")
	if f.Close() != nil || err != nil {
		return 3
	}
	args = append(args, "", "")
	key := map[string]string{"ps": "cyfrps", "exec": "schema"}[args[0]]
	if args[0] == "compose" {
		rest := args[1:]
		for slices.Contains([]string{"-p", "-f", "--project-directory", "--profile"}, rest[0]) {
			rest = rest[2:]
		}
		key = rest[0]
		switch key {
		case "exec":
			key = "rpc"
		case "run":
			key = "eval"
		case "stop":
			key = "stop-" + cmp.Or(rest[1], "all")
		}
	}
	key = cmp.Or(key, args[0])
	if out, err := os.ReadFile(filepath.Join(dir, key+".out")); err == nil {
		os.Stdout.Write(out)
	}
	if out, err := os.ReadFile(filepath.Join(dir, key+".err")); err == nil {
		os.Stderr.Write(out)
	}
	status, err := os.ReadFile(filepath.Join(dir, key+".exit"))
	if err != nil {
		return 0
	}
	n, err := strconv.Atoi(strings.TrimSpace(string(status)))
	if err != nil {
		return 3
	}
	return n
}

// dockerStandIn makes dir's docker this test binary (runFakeDocker), in
// place of the script a scenario wrote there, and fails the test unless
// PATH's docker is it.
func dockerStandIn(t *testing.T, dir string) {
	t.Helper()
	if err := os.Remove(filepath.Join(dir, "docker")); err != nil && !os.IsNotExist(err) {
		t.Fatal(err)
	}
	standInLink(t, filepath.Join(dir, "docker"))
	t.Setenv(fakeDockerAnswers, "1")
	if found, err := exec.LookPath("docker"); err != nil || found != filepath.Join(dir, "docker") {
		t.Fatalf("PATH's docker is %q (%v), not the stand-in", found, err)
	}
}

// folderState is every entry under dir, by path: its kind and mode, a
// link's target, a file's size and content digest.
func folderState(t *testing.T, dir string) map[string]string {
	t.Helper()
	state := map[string]string{}
	err := filepath.WalkDir(dir, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		info, err := os.Lstat(path)
		if err != nil {
			return err
		}
		entry := info.Mode().String()
		switch {
		case info.Mode()&fs.ModeSymlink != 0:
			target, err := os.Readlink(path)
			if err != nil {
				return err
			}
			entry += " -> " + target
		case info.Mode().IsRegular():
			data, err := os.ReadFile(path)
			if err != nil {
				return err
			}
			entry += fmt.Sprintf(" %d %x", len(data), sha256.Sum256(data))
		}
		state[path] = entry
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return state
}

func runFakeSudo(record string) int {
	f, err := os.OpenFile(record, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return 3
	}
	_, err = f.WriteString(strings.Join(os.Args[1:], " ") + "\n")
	if f.Close() != nil || err != nil {
		return 3
	}
	switch first := append(os.Args[1:], "")[0]; first {
	case "-k":
		return 0
	case "-v":
		if os.Getenv(fakeSudoVerdict) == "0" {
			return 0
		}
	}
	return 1
}

// standInLink makes path a link to this test binary, which runStandIn
// then runs as the program path names.
func standInLink(t *testing.T, path string) {
	t.Helper()
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(self, path); err != nil {
		t.Fatal(err)
	}
}

// fakeSudo puts this test binary in standInMachine's PATH folder as sudo
// (runFakeSudo), -v answering verdict, and answers the file its calls are
// recorded in. It fails the test unless PATH's sudo is the fake.
func fakeSudo(t *testing.T, verdict string) string {
	t.Helper()
	dir := os.Getenv("PATH")
	standInLink(t, filepath.Join(dir, "sudo"))
	record := filepath.Join(t.TempDir(), "calls")
	t.Setenv(fakeSudoRecord, record)
	t.Setenv(fakeSudoVerdict, verdict)
	if found, err := exec.LookPath("sudo"); err != nil || found != filepath.Join(dir, "sudo") {
		t.Fatalf("PATH's sudo is %q (%v), not the fake", found, err)
	}
	return record
}

// passwordSentence is the one line before sudo's own prompt.
const passwordSentence = "Ubuntu will now ask for your password: the one you log in to this machine with. Nothing shows while you type.\n"

func currentAccount(t *testing.T) string {
	t.Helper()
	u, err := user.Current()
	if err != nil {
		t.Fatal(err)
	}
	return u.Username
}
