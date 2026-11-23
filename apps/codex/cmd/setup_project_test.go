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
	"sync"
	"testing"
	"time"

	"github.com/cyfr/codex/internal/access"
	"github.com/cyfr/codex/internal/prompt"
)

// workStandIn is this test binary begun as setup's work (TestMain): that
// work over the fake engine, its look at Docker the real one over the
// docker on PATH where the test that began it set up a fake one, and over
// no docker at all where it did not.
//
// A test's controls: workDeaf names a folder where the work writes its pid
// and a child's, and then hears nothing; workStaleGroup has the work stand
// on Linux, older than the docker group its account is in, with no sg.
func workStandIn() int {
	if dir := os.Getenv(workDeaf); dir != "" {
		return deafWork(dir)
	}
	if os.Getenv(workStaleGroup) != "" {
		machine.system = func() string { return "linux" }
		machine.groups = func(_ context.Context, account string) []string {
			if account == "" {
				return nil
			}
			return []string{dockerGroup}
		}
		sgProgram = filepath.Join(os.TempDir(), "no-sg-here")
	}
	installFakeEngine(nil)
	if os.Getenv("FAKE_DOCKER_DIR") == "" {
		os.Setenv("PATH", "")
		machine.reachable = func(context.Context) bool { return false }
	} else {
		machine.reachable, machine.dockerHere = realMachine.reachable, realMachine.dockerHere
	}
	return Main()
}

const (
	workDeaf       = "CYFR_CMD_TEST_DEAF_WORK"
	workStaleGroup = "CYFR_CMD_TEST_STALE_GROUP"
)

// workSeesDocker has setup's work, a process of its own, reach the docker
// on this test's PATH, which logs into dir.
func workSeesDocker(t *testing.T, dir string) {
	t.Helper()
	t.Setenv("FAKE_DOCKER_DIR", dir)
}

// keepStandInControls has setup's work keep the stand-ins' own controls,
// which it needs under test alone. It is set once, in TestMain: a reading
// a page began can outlive the test that began it.
func keepStandInControls() {
	keeps := workKeeps
	workKeeps = func(name string) bool {
		return keeps(name) || name == "FAKE_DOCKER_DIR" || strings.HasPrefix(name, "CYFR_CMD_TEST_")
	}
}

// workHere has setup's work done in this process, over this test's engine
// and Docker: for what reads a folder, never a run, which takes the
// working directory and the signals of a process of its own.
func workHere(t *testing.T) {
	t.Helper()
	saved := startWork
	t.Cleanup(func() { startWork = saved })
	startWork = func(_ context.Context, args []string) (*workProcess, error) {
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
		// Work in this process cannot be killed: its pipes are cut instead.
		kill := func() { toWork.Close(); fromWork.Close() }
		return &workProcess{in: toWork, out: fromWork, wait: func() error { return <-ended }, kill: kill}, nil
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
			startWork = func(context.Context, []string) (*workProcess, error) {
				raw, err := json.Marshal(workMessage{Type: workDone, Look: look})
				_, in := io.Pipe()
				return &workProcess{in: in, out: strings.NewReader(string(raw) + "\n"), wait: func() error { return nil }, kill: func() {}}, err
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
	dir := setUpFolder(t)
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
				return &workProcess{in: in, out: strings.NewReader("not a message\n"), wait: func() error { return nil }, kill: func() {}}, nil
			},
			why: "setup's work ended before it finished",
		},
		"given up": {
			start: func() (*workProcess, error) {
				_, in := io.Pipe()
				out, _ := io.Pipe()
				return &workProcess{in: in, out: out, wait: func() error { return nil }, kill: func() {}}, nil
			},
			why: "it was ended before it answered",
		},
	} {
		t.Run(name, func(t *testing.T) {
			saved := startWork
			t.Cleanup(func() { startWork = saved })
			startWork = func(context.Context, []string) (*workProcess, error) { return c.start() }
			ctx, end := context.WithTimeout(t.Context(), 200*time.Millisecond)
			defer end()
			f, _, err := openFolder(dir, "the test")
			if err != nil {
				t.Fatal(err)
			}
			looked := make(chan error, 1)
			go func() {
				_, err := f.look(ctx, workLook, dir)
				looked <- err
			}()
			select {
			case err = <-looked:
			case <-time.After(10 * time.Second):
				t.Fatal("the reading was waited for past its caller")
			}
			want := "The CYFR in " + dir + " could not be read here (" + c.why + "), so nothing was sent to it. Try again."
			if err == nil || err.Error() != want {
				t.Fatalf("said %v, want %q", err, want)
			}
		})
	}
}

// setUpFolder is a folder a CYFR is set up in, read and opened alone.
func setUpFolder(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, ".env"), []byte("CYFR_ACCESS=local\nCYFR_PORT=4100\nCYFR_LOCUS_BUILDS_URL=\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	return dir
}

// heldLauncher stands in for a launcher held in what it asks first: it
// says each start on starting and waits for release, not for its ctx.
// Each ctx it was given is on given.
func heldLauncher(t *testing.T) (starting chan struct{}, given chan context.Context, release func()) {
	t.Helper()
	saved := startWork
	t.Cleanup(func() { startWork = saved })
	starting, given = make(chan struct{}, 8), make(chan context.Context, 8)
	released := make(chan struct{})
	release = sync.OnceFunc(func() { close(released) })
	t.Cleanup(release)
	startWork = func(ctx context.Context, _ []string) (*workProcess, error) {
		given <- ctx
		starting <- struct{}{}
		<-released
		return nil, errors.New("the test's launcher let go")
	}
	return starting, given, release
}

// A reading whose caller has gone starts no work, a run neither.
func TestACancelledReadingStartsNothing(t *testing.T) {
	for _, args := range [][]string{{workProbe}, {workLook, t.TempDir()}, {workToken, t.TempDir(), "the test"}, {workRun, t.TempDir()}} {
		t.Run(args[0], func(t *testing.T) {
			ctx, cancel := context.WithCancel(t.Context())
			cancel()
			started := false
			_, err := workBegunBy(ctx, func(context.Context, []string) (*workProcess, error) {
				started = true
				return nil, io.ErrClosedPipe
			}, nil, args...)
			if started || !errors.Is(err, context.Canceled) {
				t.Fatalf("started %t, answered %v", started, err)
			}
		})
	}
}

// A reading is not waited for while its work is still starting: its caller
// goes at its ctx's end, and the launcher's ctx ends with it.
func TestAReadingIsNotWaitedForWhileItsWorkStarts(t *testing.T) {
	starting, given, _ := heldLauncher(t)
	f, _, err := openFolder(setUpFolder(t), "the test")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(t.Context())
	looked := make(chan error, 1)
	go func() {
		_, err := f.look(ctx, workLook, f.dir)
		looked <- err
	}()
	<-starting
	cancel()
	select {
	case err = <-looked:
	case <-time.After(5 * time.Second):
		t.Fatal("the reading waited for its work to start")
	}
	if !strings.Contains(err.Error(), "it was ended before it answered") {
		t.Fatalf("said %v", err)
	}
	if (<-given).Err() == nil {
		t.Fatal("the launcher's ctx outlived the reading")
	}
}

// An ended folder ends its readings, starting ones too, at once: End waits
// for no launcher, and a reading after it starts nothing and says why.
func TestAnEndedFolderEndsItsReadingsAtOnce(t *testing.T) {
	starting, given, _ := heldLauncher(t)
	l, err := readLocal(setUpFolder(t), "the test")
	if err != nil {
		t.Fatal(err)
	}
	read := make(chan error, 1)
	go func() { read <- l.Answers(t.Context()) }()
	<-starting
	returns := make(chan struct{})
	go func() {
		l.End()
		close(returns)
	}()
	select {
	case <-returns:
	case <-time.After(5 * time.Second):
		t.Fatal("End waited for the launcher")
	}
	select {
	case err = <-read:
	case <-time.After(5 * time.Second):
		t.Fatal("the reading outlived its folder's end")
	}
	if !strings.Contains(err.Error(), "what opened this CYFR has ended") {
		t.Fatalf("the reading in flight said %v", err)
	}
	if (<-given).Err() == nil {
		t.Fatal("the launcher's ctx outlived the folder")
	}
	err = l.Answers(t.Context())
	if err == nil || !strings.Contains(err.Error(), "what opened this CYFR has ended") {
		t.Fatalf("a reading after the end said %v", err)
	}
	select {
	case <-starting:
		t.Fatal("a reading after the end started work")
	default:
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
		machine.groups = func(_ context.Context, account string) []string {
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
