// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bytes"
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
	"github.com/cyfr/codex/internal/shell"
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
	real := openEngineAs
	installFakeEngine(nil)
	if os.Getenv(workRealEngine) != "" {
		// The run's start through the real engine, over the docker on
		// PATH.
		openEngineAs = real
	}
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
	// workRealEngine names the real docker whose Compose resolves the
	// folder's configuration, for a run whose start goes through the real
	// engine (workDocker hands it compose config).
	workRealEngine = "CYFR_CMD_TEST_REAL_DOCKER"
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
		return keeps(name) || name == "FAKE_DOCKER_DIR" || name == "GORACE" || strings.HasPrefix(name, "CYFR_CMD_TEST_")
	}
}

// workHere has setup's work done in this process, over this test's engine
// and Docker: for what reads a folder, never a run, which takes the
// working directory and the signals of a process of its own.
func workHere(t *testing.T) {
	t.Helper()
	saved := startWork
	t.Cleanup(func() { startWork = saved })
	startWork = func(_ context.Context, args []string) (workBegin, error) {
		if args[0] == workRun {
			return nil, errors.New("a run takes a process of its own")
		}
		return func() (*workProcess, error) { return workInThisProcess(args), nil }, nil
	}
}

// workInThisProcess is setup's work args done in this process.
func workInThisProcess(args []string) *workProcess {
	{
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
		return &workProcess{in: toWork, out: fromWork, wait: func() error { return <-ended }, kill: kill}
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
			startWork = func(context.Context, []string) (workBegin, error) {
				raw, err := json.Marshal(workMessage{Type: workDone, Look: look})
				_, in := io.Pipe()
				return begins(&workProcess{in: in, out: strings.NewReader(string(raw) + "\n"), wait: func() error { return nil }, kill: func() {}}), err
			}
			dialTCP = func(context.Context, string, string) (net.Conn, error) {
				t.Error("a connection was made")
				return nil, errors.New("the test makes no connection")
			}
			l, err := readLocal(shell.NewWork(t.Context()), dir, "the test")
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
			startWork = func(context.Context, []string) (workBegin, error) { return c.start, nil }
			ctx, end := context.WithTimeout(t.Context(), 200*time.Millisecond)
			defer end()
			f, _, err := openFolder(shell.NewWork(t.Context()), dir, "the test")
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

// A Docker check whose work never answered says what happened to the
// work, and that Docker was not asked only where the work never began.
func TestADockerCheckThatNeverCameBackSaysWhatHappened(t *testing.T) {
	for name, c := range map[string]struct {
		start func() (*workProcess, error)
		said  string
	}{
		"not begun": {
			start: func() (*workProcess, error) { return nil, errors.New("sg is gone") },
			said:  "Docker was not asked (setup's work could not begin (sg is gone))",
		},
		"ended with no answer": {
			start: func() (*workProcess, error) {
				_, in := io.Pipe()
				return &workProcess{in: in, out: strings.NewReader("not a message\n"), wait: func() error { return nil }, kill: func() {}}, nil
			},
			said: "The Docker check failed (setup's work ended before it finished)",
		},
	} {
		t.Run(name, func(t *testing.T) {
			saved := startWork
			t.Cleanup(func() { startWork = saved })
			startWork = func(context.Context, []string) (workBegin, error) { return c.start, nil }
			if got := dockerCheck(t.Context(), shell.NewWork(t.Context())); got.Sentence != c.said || got.Ready {
				t.Fatalf("the check answered %+v, want %q", got, c.said)
			}
		})
	}
}

// begins is a stand-in's begin of w.
func begins(w *workProcess) workBegin { return func() (*workProcess, error) { return w, nil } }

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
	startWork = func(ctx context.Context, _ []string) (workBegin, error) {
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

// A run, setup a person started, whose caller goes while it is still
// starting is waited for to its end all the same.
func TestARunIsWaitedForThoughItsCallerWentAsItStarted(t *testing.T) {
	ctx, cancel := context.WithCancel(t.Context())
	entered, release := make(chan struct{}), make(chan struct{})
	answered := make(chan error, 1)
	go func() {
		_, err := workBegunBy(ctx, func(context.Context, []string) (*workProcess, error) {
			close(entered)
			<-release
			_, in := io.Pipe()
			return &workProcess{in: in, out: strings.NewReader(`{"type":"done"}` + "\n"), wait: func() error { return nil }, kill: func() {}}, nil
		}, nil, workRun, t.TempDir())
		answered <- err
	}()
	<-entered
	cancel()
	select {
	case err := <-answered:
		t.Fatalf("the run answered %v before it started", err)
	case <-time.After(100 * time.Millisecond): // sleep-ok: a bounded look for an answer that must not come yet
	}
	close(release)
	select {
	case err := <-answered:
		if err != nil {
			t.Fatalf("the run answered %v, not its end", err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("the run never answered")
	}
}

// A reading is not waited for while its work is still starting: its caller
// goes at its ctx's end, and the launcher's ctx ends with it.
func TestAReadingIsNotWaitedForWhileItsWorkStarts(t *testing.T) {
	starting, given, _ := heldLauncher(t)
	f, _, err := openFolder(shell.NewWork(t.Context()), setUpFolder(t), "the test")
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
// than it and Docker's socket refused it, says what gives it the group: a
// new login. A daemon that is not there says so, whatever the membership.
func TestDockerReadySaysWhenALoginIsWhatIsMissing(t *testing.T) {
	saved := machine
	t.Cleanup(func() { machine = saved })
	machine.reachable = func(context.Context) bool { return false }
	member := []string{dockerGroup}
	for _, c := range []struct {
		system        string
		account, mine []string
		// refused is what docker wrote where it did not answer.
		refused string
		login   bool
		// elsewhere is a Docker whose endpoint is another computer's,
		// which no login cures.
		elsewhere bool
	}{
		{"linux", member, nil, socketDenied, true, false},
		{"linux", member, nil, noDaemon, false, false},
		{"linux", member, member, socketDenied, false, false},
		{"linux", nil, nil, socketDenied, false, false},
		{"darwin", member, nil, socketDenied, false, false},
		{"linux", member, nil, socketDenied, false, true},
	} {
		machine.dockerHere = func(context.Context) (bool, error) { return !c.elsewhere, nil }
		machine.system = func() string { return c.system }
		machine.groups = func(_ context.Context, account string) []string {
			if account == "" {
				return c.mine
			}
			return c.account
		}
		machine.refusal = refusedWith(c.refused)
		ready, why, fixable := dockerReady(t.Context())
		if ready || strings.Contains(why, "log out and in again") != c.login || strings.Contains(why, "another computer") != c.elsewhere {
			t.Errorf("%+v: ready %v, %q", c, ready, why)
		}
		if c.refused == noDaemon && why != "Docker does not answer this account: the Docker daemon is not reachable" {
			t.Errorf("%+v: no daemon is said as %q", c, why)
		}
		if fixable != (!c.login && !c.elsewhere) {
			t.Errorf("%+v: %q offers a remedy: %v", c, why, fixable)
		}
	}
}

// The one Docker sentence names the cause asking Docker saw, and offers
// what installs, starts or joins Docker only where that is what is
// missing: a new login only for this computer's own socket refusing a
// process older than the account's group.
func TestTheDockerSentenceNamesOnlyWhatWasSeen(t *testing.T) {
	denied := func(text string) dockerSeen {
		kind, said := access.ReadDockerRefusal([]byte(text))
		return dockerSeen{here: true, refusal: kind, said: said}
	}
	stale := func(s dockerSeen) dockerSeen { s.stale = true; return s }
	elsewhere := func(s dockerSeen) dockerSeen { s.here = false; return s }
	const tcpDenied = "permission denied while trying to connect to the docker API at tcp://192.0.2.1:2375\n"
	for _, c := range []struct {
		name    string
		seen    dockerSeen
		why     string
		fixable bool
	}{
		{"socket refused, the group newer than the process", stale(denied(socketDenied)), loginAgain, false},
		{"socket refused, the group the process's own", denied(socketDenied),
			"Docker does not answer this account: this user may not use the Docker daemon", true},
		{"refused over TCP, the group newer than the process", elsewhere(stale(denied(tcpDenied))),
			"Docker here runs containers on another computer, so CYFR cannot be set up on this one with it", false},
		{"no daemon, the group newer than the process", stale(denied(noDaemon)),
			"Docker does not answer this account: the Docker daemon is not reachable", true},
		{"the client's API version refused", stale(denied("Error response from daemon: client version 1.52 is too new. Maximum supported API version is 1.47\n")),
			"Docker's daemon refused this account: client version 1.52 is too new. Maximum supported API version is 1.47", false},
		{"Docker absent", dockerSeen{hereErr: errors.New("exec: docker: not found"), absent: true}, "Docker is not installed here", true},
		{"any other words", denied("context \"gone\" does not exist\n"), "Docker does not answer this account: context \"gone\" does not exist", false},
		{"nothing said", denied(""), "Docker does not answer this account", true},
		{"where it runs unread", dockerSeen{hereErr: errors.New("exit status 1")}, "Docker did not say where it runs containers", true},
		{"given up on", dockerSeen{cancelled: true, here: true}, "Docker was not waited for", false},
		{"answering", dockerSeen{here: true, answers: true}, "", false},
	} {
		if why, fixable := dockerSentence(c.seen); why != c.why || fixable != c.fixable {
			t.Errorf("%s: said %q, offers a remedy %v; want %q, %v", c.name, why, fixable, c.why, c.fixable)
		}
	}
}

// The probe's answer names what makes Docker answer here, only where
// installing, starting or joining is what is missing: the commands on
// Ubuntu 26.04, Docker Desktop's page on macOS and Windows, Docker's own
// page on any other Linux; none for a Docker elsewhere, a login missing,
// or a Docker that answers.
func TestTheProbeNamesWhatMakesDockerAnswerHere(t *testing.T) {
	saved := machine
	t.Cleanup(func() { machine = saved })
	machine.installed = func(string) bool { return false }
	machine.running = func() bool { return false }
	machine.groups = func(context.Context, string) []string { return nil }
	machine.refusal = refusedWith(noDaemon)
	for _, c := range []struct {
		name, system  string
		supported     bool
		here, answers bool
		hereErr       error
		commands      bool
		page          string
	}{
		{"Ubuntu 26.04 without Docker", "linux", true, true, false, nil, true, ""},
		{"Ubuntu 26.04, Docker not installed", "linux", true, false, false, errors.New("no docker"), true, ""},
		{"another Linux", "linux", false, true, false, nil, false, dockerEnginePage},
		{"macOS", "darwin", false, true, false, nil, false, dockerDesktopPage},
		{"Windows", "windows", false, false, false, errors.New("no docker"), false, dockerDesktopPage},
		{"a Docker elsewhere", "darwin", false, false, false, nil, false, ""},
		{"a Docker that answers", "linux", true, true, true, nil, false, ""},
	} {
		t.Run(c.name, func(t *testing.T) {
			machine.system = func() string { return c.system }
			machine.supported = func() bool { return c.supported }
			machine.dockerHere = func(context.Context) (bool, error) { return c.here, c.hereErr }
			machine.reachable = func(context.Context) bool { return c.answers }
			var out bytes.Buffer
			// The end of its stdin is the work's cancel: held open.
			in, held := io.Pipe()
			defer held.Close()
			_ = runSetupWork(t.Context(), in, &out, []string{workProbe})
			var m workMessage
			if err := json.Unmarshal(out.Bytes(), &m); err != nil {
				t.Fatalf("the probe said %q", out.String())
			}
			if m.Type != workDone || m.Ready != c.answers || (len(m.Commands) > 0) != c.commands || m.Page != c.page {
				t.Fatalf("the probe answered %+v", m)
			}
			if c.commands && !slices.Contains(m.Commands, "systemctl enable --now docker") {
				t.Fatalf("the commands are %q", m.Commands)
			}
		})
	}
}

// Every page the probe can name is one main opens in the person's
// browser (tests/fixtures/desktop-process.json external_pages).
func TestEveryPageTheProbeNamesIsOneMainOpens(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "tests", "fixtures", "desktop-process.json"))
	if err != nil {
		t.Fatal(err)
	}
	var v struct {
		Pages []string `json:"external_pages"`
	}
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatal(err)
	}
	for _, page := range []string{dockerDesktopPage, dockerEnginePage} {
		if !slices.Contains(v.Pages, page) {
			t.Errorf("main does not open %s", page)
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
