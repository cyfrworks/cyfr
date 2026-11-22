// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"testing"

	"github.com/cyfr/codex/internal/access"
	"github.com/cyfr/codex/internal/prompt"
)

// workStandIn is this test binary begun as setup's work (TestMain): that
// work over the fake engine, its look at Docker the real one over the
// docker on PATH where the test that began it set up a fake one, and over
// no docker at all where it did not.
func workStandIn() int {
	installFakeEngine(nil)
	if os.Getenv("FAKE_DOCKER_DIR") == "" {
		os.Setenv("PATH", "")
		machine.reachable = func(context.Context) bool { return false }
	} else {
		machine.reachable, machine.dockerHere = realMachine.reachable, realMachine.dockerHere
	}
	return Main()
}

// workSeesDocker has setup's work, a process of its own, reach the docker
// on this test's PATH, which logs into dir: the work keeps the stand-ins'
// own controls, which it needs under test alone.
func workSeesDocker(t *testing.T, dir string) {
	t.Helper()
	t.Setenv("FAKE_DOCKER_DIR", dir)
	saved := workKeeps
	t.Cleanup(func() { workKeeps = saved })
	workKeeps = func(name string) bool {
		return saved(name) || name == "FAKE_DOCKER_DIR" || strings.HasPrefix(name, "CYFR_CMD_TEST_")
	}
}

// workHere has setup's work done in this process, over this test's engine
// and Docker: for what reads a folder, never a run, which takes the
// working directory and the signals of a process of its own.
func workHere(t *testing.T) {
	t.Helper()
	saved := startWork
	t.Cleanup(func() { startWork = saved })
	startWork = func(args []string) (*workProcess, error) {
		if args[0] == workRun {
			return nil, errors.New("a run takes a process of its own")
		}
		in, toWork := io.Pipe()
		fromWork, out := io.Pipe()
		ended := make(chan error, 1)
		go func() {
			err := runSetupWork(context.Background(), in, out, args)
			out.Close()
			in.Close()
			ended <- err
		}()
		return &workProcess{in: toWork, out: fromWork, wait: func() error { return <-ended }}, nil
	}
}

// An answer of setup's work that names no container lets no connection be
// made and offers no token, whatever else it says.
func TestALookNamingNoContainerSendsNothing(t *testing.T) {
	dir := t.TempDir()
	env := "CYFR_ACCESS=local\nCYFR_PORT=4100\nCYFR_LOCUS_BUILDS_URL=\n" + setupTokenVar + "=" + testToken + "\n"
	if err := os.WriteFile(filepath.Join(dir, ".env"), []byte(env), 0o600); err != nil {
		t.Fatal(err)
	}
	read, err := readFolder(dir)
	if err != nil {
		t.Fatal(err)
	}
	for name, look := range map[string]*folderLook{
		"no reading":   nil,
		"no container": {Bound: read.localBound, Token: testToken},
	} {
		t.Run(name, func(t *testing.T) {
			saved, savedDial := startWork, dialTCP
			t.Cleanup(func() { startWork, dialTCP = saved, savedDial })
			startWork = func([]string) (*workProcess, error) {
				raw, err := json.Marshal(workMessage{Type: workDone, Look: look})
				_, in := io.Pipe()
				return &workProcess{in: in, out: strings.NewReader(string(raw) + "\n"), wait: func() error { return nil }}, err
			}
			dialTCP = func(context.Context, string, string) (net.Conn, error) {
				t.Error("a connection was made")
				return nil, errors.New("the test makes no connection")
			}
			l, err := readLocal(dir, "the test")
			if err != nil {
				t.Fatal(err)
			}
			if token, through := l.Shell.SetupToken(t.Context()); token != "" || through != nil {
				t.Error("the token was offered")
			}
			if err := l.Answers(t.Context()); err == nil || !strings.Contains(err.Error(), "named no container") {
				t.Errorf("it answers %v", err)
			}
		})
	}
}

// A reading that never came back from setup's work says so, and blames no
// Docker it did not see: the work may not have begun, ended with no
// answer, or not answered before it was given up.
func TestAReadingThatNeverCameBackBlamesNoDocker(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, ".env"), []byte("CYFR_ACCESS=local\nCYFR_PORT=4100\nCYFR_LOCUS_BUILDS_URL=\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	read, err := readFolder(dir)
	if err != nil {
		t.Fatal(err)
	}
	for name, c := range map[string]struct {
		start func() (*workProcess, error)
		why   string
	}{
		"not begun": {
			start: func() (*workProcess, error) { return nil, errors.New("sg is gone") },
			why:   "setup's work could not begin (sg is gone)",
		},
		"ended with no answer": {
			start: func() (*workProcess, error) {
				_, in := io.Pipe()
				return &workProcess{in: in, out: strings.NewReader("not a message\n"), wait: func() error { return nil }}, nil
			},
			why: "setup's work ended before it finished",
		},
		"given up": {
			start: func() (*workProcess, error) {
				_, in := io.Pipe()
				out, _ := io.Pipe()
				return &workProcess{in: in, out: out, wait: func() error { return nil }}, nil
			},
			why: "it was ended before it answered",
		},
	} {
		t.Run(name, func(t *testing.T) {
			saved := startWork
			t.Cleanup(func() { startWork = saved })
			startWork = func([]string) (*workProcess, error) { return c.start() }
			ended, end := context.WithCancel(t.Context())
			if name == "given up" {
				end()
			}
			defer end()
			f := &localFolder{dir: dir, opened: read.localBound}
			_, err := f.look(ended, workLook, dir)
			want := "The CYFR in " + dir + " could not be read here (" + c.why + "), so nothing was sent to it. Try again."
			if err == nil || err.Error() != want {
				t.Fatalf("said %v, want %q", err, want)
			}
		})
	}
}

// Setup's work gets which account, system and Docker it runs on and no
// setting of a CYFR, and on macOS and Windows Docker Desktop's own docker
// after PATH, which an app started from the desktop lacks.
func TestSetupsWorkGetsNoSettingOfACYFR(t *testing.T) {
	savedDesktop, savedSystem := dockerDesktop, machine.system
	t.Cleanup(func() { dockerDesktop, machine.system = savedDesktop, savedSystem })
	dockerDesktop = func(string) (string, string) { return "app", "desktop-bin" }
	given := []string{
		"CYFR_ACCESS=public", "CYFR_PORT=4999", "CYFR_SETUP_TOKEN=launchers", "CYFR_DIRECTORY_URL=https://launcher.example",
		"COMPOSE_PROJECT_NAME=other", "LOCUS_RUNTIME_KEY=k", "ELECTRON_RUN_AS_NODE=1", "SOMETHING=else",
		"HOME=/home/ada", "https_proxy=http://proxy:3128", "LC_ALL=C.UTF-8", "DOCKER_CONFIG=/home/ada/.docker", "Path=the-path",
	}
	kept := []string{"HOME=/home/ada", "https_proxy=http://proxy:3128", "LC_ALL=C.UTF-8", "DOCKER_CONFIG=/home/ada/.docker"}
	after := "the-path" + string(os.PathListSeparator) + "desktop-bin"
	for system, want := range map[string][]string{
		"linux":   append(slices.Clone(kept), "Path=the-path"),
		"darwin":  append(slices.Clone(kept), "PATH="+after),
		"windows": append(slices.Clone(kept), "PATH="+after),
	} {
		machine.system = func() string { return system }
		if got := workEnvironment(given); !slices.Equal(got, want) {
			t.Errorf("%s gets %q, want %q", system, got, want)
		}
	}
}

// A folder Docker can name no project after is refused by cyfr init before
// anything is written, as every start would refuse it after.
func TestInitRefusesAFolderDockerCannotName(t *testing.T) {
	template := readShippedTemplate(t)
	dir := filepath.Join(t.TempDir(), "---")
	if err := os.Mkdir(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Chdir(dir)
	if err := os.WriteFile(".env.example", []byte(template), 0o644); err != nil {
		t.Fatal(err)
	}
	err := initProject(t.Context(), initOptions{noPull: true}, nil, io.Discard, io.Discard)
	if err == nil || !strings.Contains(err.Error(), "needs a letter a to z or a digit") {
		t.Fatalf("init answered %v", err)
	}
	if entries, err := os.ReadDir("."); err != nil || len(entries) != 1 {
		t.Fatalf("it wrote %d entries (%v)", len(entries)-1, err)
	}
}

// An interrupt that came while the project's files downloaded, which takes
// none, is heeded before any key is minted.
func TestInitHeedsAnInterruptBeforeItMintsKeys(t *testing.T) {
	newInitProject(t)
	ctx, cancel := context.WithCancel(t.Context())
	cancel()
	err := initProject(ctx, initOptions{noPull: true}, nil, io.Discard, io.Discard)
	if !errors.Is(err, prompt.ErrAborted) || fileExists(".env") {
		t.Fatalf("init answered %v, .env written %v", err, fileExists(".env"))
	}
}

// Work that came through no sg, where the account's membership is newer
// than it, says what gives it the group: a new login.
func TestDockerReadySaysWhenALoginIsWhatIsMissing(t *testing.T) {
	saved := machine
	t.Cleanup(func() { machine = saved })
	machine.reachable = func(context.Context) bool { return false }
	member := []string{dockerGroup}
	for _, c := range []struct {
		system        string
		account, mine []string
		login         bool
	}{
		{"linux", member, nil, true},
		{"linux", member, member, false},
		{"linux", nil, nil, false},
		{"darwin", member, nil, false},
	} {
		machine.system = func() string { return c.system }
		machine.groups = func(account string) []string {
			if account == "" {
				return c.mine
			}
			return c.account
		}
		if ready, why := dockerReady(t.Context()); ready || strings.Contains(why, "log out and in again") != c.login {
			t.Errorf("%+v: ready %v, %q", c, ready, why)
		}
	}
}

// publishing has the fake docker say container c0ffee of the folder at dir
// runs publishing port, its log logs.
func (s localStack) publishing(dir string, port int, logs string) {
	s.t.Helper()
	s.answer("context.out", "unix:///var/run/docker.sock\n")
	s.runs("c0ffee", dir, nil, port)
	s.answer("logs.out", logs)
}

// portOf is the port the .env in dir names.
func portOf(t *testing.T, dir string) string {
	t.Helper()
	_, head, err := access.ReadProjectAlone(dir)
	if err != nil {
		t.Fatal(err)
	}
	return strconv.Itoa(head.Port)
}
