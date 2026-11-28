//go:build unix

// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/cyfr/codex/internal/access"
	"github.com/cyfr/codex/internal/desktop"
	"github.com/cyfr/codex/internal/shell"
)

// workDocker stands in for docker for setup's work, a process of its own.
// It logs each call, keeps the environment its info was asked in, waits
// for <key>.release where <key>.block is, and answers <key>.out and
// <key>.exit: key is the subcommand, up for a compose up and cyfrps for ps.
// A compose config is held at config.block, and answered as compose.
const workDocker = `#!/bin/sh
d="$FAKE_DOCKER_DIR"
printf '%s\n' "$*" >>"$d/log"
k="$1"
case " $* " in " compose "*" up "*) k=up ;; esac
[ "$k" = ps ] && k=cyfrps
[ "$k" = info ] && env >"$d/environ"
printf '%s %s\n' "$1" "$(pwd -P)" >>"$d/cwd"
h=$k
case " $* " in " compose "*" config "*) h=config ;; esac
if [ -f "$d/$h.block" ]; then
  printf '%s\n' "$$" >"$d/$h.pid"
  while [ ! -f "$d/$h.release" ]; do sleep 0.02; done
  : >"$d/$h.ended"
fi
# The stack's containers, where stack.out says them.
case " $* " in *"label=com.docker.compose.project="*) [ -f "$d/stack.out" ] && exec cat "$d/stack.out" ;; esac
# Under the real engine, the real Compose resolves the configuration.
[ "$h" = config ] && [ -n "$CYFR_CMD_TEST_REAL_DOCKER" ] && exec "$CYFR_CMD_TEST_REAL_DOCKER" "$@"
[ -f "$d/$k.out" ] && cat "$d/$k.out"
[ -f "$d/$k.exit" ] && exit "$(cat "$d/$k.exit")"
exit 0
`

// workProject is a folder for setup's work to set CYFR up in, the work a
// process of its own over workDocker, and no other docker on its PATH.
type workProject struct {
	localStack
	// tools is the one other folder on PATH.
	tools string
}

func newWorkProject(t *testing.T) workProject {
	t.Helper()
	template, compose := readShippedTemplate(t), shippedCompose(t)
	fake, tools, parent := t.TempDir(), t.TempDir(), t.TempDir()
	dir := filepath.Join(parent, "cyfr")
	p := workProject{localStack{updateScenario: &updateScenario{t: t, project: dir, fake: fake}}, tools}
	if err := os.Mkdir(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, ".env.example"), []byte(template), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "docker-compose.yml"), compose, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(fake, "docker"), []byte(workDocker), 0o755); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"sleep", "cat", "env"} {
		program, err := exec.LookPath(name)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(program, filepath.Join(tools, name)); err != nil {
			t.Fatal(err)
		}
	}
	p.answer("context.out", "unix:///var/run/docker.sock\n")
	t.Setenv("PATH", fake+string(os.PathListSeparator)+tools)
	workSeesDocker(t, fake)

	saved, savedSg, savedDesktop := machine, sgProgram, dockerDesktop
	t.Cleanup(func() { machine, sgProgram, dockerDesktop = saved, savedSg, savedDesktop })
	machine.system = func() string { return "linux" }
	sgProgram = filepath.Join(fake, "no-sg")
	return p
}

// run asks setup's work to set CYFR up in dir, answering the steps it
// reported.
func (p workProject) run(ctx context.Context, dir string) ([]string, error) {
	var steps []string
	_, err := setupWork(ctx, shell.NewWork(ctx), func(s string) { steps = append(steps, s) }, workRun, dir)
	return steps, err
}

func (p workProject) count(prefix string) int {
	n := 0
	for _, line := range p.log() {
		if strings.HasPrefix(line, prefix) {
			n++
		}
	}
	return n
}

func (p workProject) starts() int { return p.count("ENGINE start ") }

func (p workProject) has(name string) bool {
	_, err := os.Stat(filepath.Join(p.fake, name))
	return err == nil
}

// await waits for what to hold.
func (p workProject) await(what string, holds func() bool) {
	p.t.Helper()
	deadline := time.Now().Add(20 * time.Second)
	for !holds() {
		if time.Now().After(deadline) {
			p.t.Fatalf("waited for %s", what)
		}
		time.Sleep(20 * time.Millisecond) // sleep-ok: the poll of a wait bounded by deadline
	}
}

// blocked waits for docker's key call to block and answers its process.
func (p workProject) blocked(key string) int {
	p.t.Helper()
	var pid int
	p.await("docker "+key, func() bool {
		raw, err := os.ReadFile(filepath.Join(p.fake, key+".pid"))
		if err != nil {
			return false
		}
		pid, err = strconv.Atoi(strings.TrimSpace(string(raw)))
		return err == nil && pid > 0
	})
	return pid
}

func readEnv(t *testing.T, dir string) string {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join(dir, ".env"))
	if err != nil {
		t.Fatal(err)
	}
	return string(raw)
}

// recordWorksStdout answers what setup's work wrote on its stdout, whole.
func recordWorksStdout(t *testing.T) *bytes.Buffer {
	t.Helper()
	said, saved := &bytes.Buffer{}, startWork
	t.Cleanup(func() { startWork = saved })
	prepare := preparer()
	startWork = func(ctx context.Context, args []string) (workBegin, error) {
		begin, err := prepare(ctx, args)
		if err != nil {
			return nil, err
		}
		return func() (*workProcess, error) {
			w, err := begin()
			if err == nil {
				w.out = io.TeeReader(w.out, said)
			}
			return w, err
		}, nil
	}
	return said
}

// One action sets CYFR up in a folder and starts it once: init's steps
// then the start. Asked again it mints nothing again and starts. Neither
// the setup token nor a setup link is on its stdout.
func TestSetupsWorkSetsUpAFolderAndStartsIt(t *testing.T) {
	p := newWorkProject(t)
	said := recordWorksStdout(t)
	steps, err := p.run(t.Context(), p.project)
	if err != nil || !slices.Equal(steps, []string{"files", "settings", "images", "start"}) {
		t.Fatalf("the run answered %v after %v", err, steps)
	}
	if p.starts() != 1 || p.count("pull ") < 2 {
		t.Fatalf("CYFR was started %d times after %d pulls", p.starts(), p.count("pull "))
	}
	env := readEnv(t, p.project)
	token, _ := parseEnvFile(env).value(setupTokenVar)
	if len(token) != 64 {
		t.Fatalf("no setup token was written")
	}
	if info, err := os.Stat(filepath.Join(p.project, ".env")); err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf(".env is %v (%v)", info, err)
	}

	steps, err = p.run(t.Context(), p.project)
	if err != nil || !slices.Equal(steps, []string{"start"}) || p.starts() != 2 {
		t.Fatalf("asked again it answered %v after %v, %d starts", err, steps, p.starts())
	}
	if readEnv(t, p.project) != env {
		t.Fatal("asked again it changed .env")
	}
	if out := said.String(); strings.Contains(out, token) || strings.Contains(out, "/setup#") {
		t.Fatal("the work's stdout carries the setup token")
	}
}

// What setup cannot complete is refused in a sentence before anything is
// written or started.
func TestSetupsWorkRefusesBeforeItWrites(t *testing.T) {
	for _, c := range []struct {
		name, words string
		folder      func(t *testing.T, p workProject) string
	}{
		{"Docker not answering", "Docker does not answer this account. Nothing was written", func(_ *testing.T, p workProject) string {
			p.answer("info.exit", "1")
			return filepath.Join(filepath.Dir(p.project), "new")
		}},
		{"Docker on another computer", "containers on another computer", func(_ *testing.T, p workProject) string {
			p.answer("context.out", "tcp://192.0.2.1:2375\n")
			return filepath.Join(filepath.Dir(p.project), "new")
		}},
		{"Docker not saying where it runs", "did not say where it runs containers", func(_ *testing.T, p workProject) string {
			p.answer("context.exit", "1")
			return filepath.Join(filepath.Dir(p.project), "new")
		}},
		{"a name Docker cannot use", "needs a letter a to z or a digit", func(_ *testing.T, p workProject) string {
			return filepath.Join(filepath.Dir(p.project), "---")
		}},
		{"the account's own folder", "choose a folder inside it", func(t *testing.T, p workProject) string {
			home := t.TempDir()
			t.Setenv("HOME", home)
			return home
		}},
		{"a link to the account's own folder", "choose a folder inside it", func(t *testing.T, p workProject) string {
			home := t.TempDir()
			t.Setenv("HOME", home)
			link := filepath.Join(t.TempDir(), "mine")
			if err := os.Symlink(home, link); err != nil {
				t.Fatal(err)
			}
			return link
		}},
	} {
		t.Run(c.name, func(t *testing.T) {
			p := newWorkProject(t)
			dir := c.folder(t, p)
			_, before := os.Stat(dir)
			steps, err := p.run(t.Context(), dir)
			if err == nil || !strings.Contains(err.Error(), c.words) || len(steps) != 0 {
				t.Fatalf("it answered %v after %v, want %q", err, steps, c.words)
			}
			if before != nil {
				if _, err := os.Stat(dir); !errors.Is(err, os.ErrNotExist) {
					t.Fatalf("it made the folder (%v)", err)
				}
			} else if entries, err := os.ReadDir(dir); err != nil || len(entries) != 0 {
				t.Fatalf("it wrote %v (%v)", entries, err)
			}
			if p.starts() != 0 || p.count("pull ") != 0 {
				t.Fatalf("it ran %v", p.log())
			}
		})
	}
}

// A folder that is not there is made, and one with nothing to write .env
// from says so rather than start.
func TestSetupsWorkMakesTheFolder(t *testing.T) {
	p := newWorkProject(t)
	dir := filepath.Join(filepath.Dir(p.project), "not", "there", "yet")
	_, err := p.run(t.Context(), dir)
	if err == nil || !strings.Contains(err.Error(), "no .env.example") || p.starts() != 0 {
		t.Fatalf("it answered %v after %d starts", err, p.starts())
	}
	if info, err := os.Stat(dir); err != nil || !info.IsDir() {
		t.Fatalf("the folder was not made (%v)", err)
	}
}

// Two setups of one folder are one: the second changes nothing.
func TestSetupsWorkRunsOneSetupAFolder(t *testing.T) {
	p := newWorkProject(t)
	lock := filepath.Join(p.project, setupLockFile)
	if err := os.MkdirAll(filepath.Dir(lock), 0o700); err != nil {
		t.Fatal(err)
	}
	release, busy, err := access.LockFile(lock)
	if err != nil || busy {
		t.Fatalf("the lock was not taken (%v, busy %v)", err, busy)
	}
	defer release()
	_, err = p.run(t.Context(), p.project)
	if err == nil || !strings.Contains(err.Error(), "still running") || p.starts() != 0 {
		t.Fatalf("the second answered %v after %d starts", err, p.starts())
	}
	if _, err := os.Stat(filepath.Join(p.project, ".env")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("the second wrote .env (%v)", err)
	}
}

// The folder keeps the name it was chosen by, through a link too: compose
// names the project after it, which is what opens the folder later.
func TestSetupsWorkNamesTheProjectAsTheFolderWasChosen(t *testing.T) {
	p := newWorkProject(t)
	chosen := filepath.Join(t.TempDir(), "chosen")
	if err := os.Symlink(p.project, chosen); err != nil {
		t.Fatal(err)
	}
	if _, err := p.run(t.Context(), chosen); err != nil {
		t.Fatal(err)
	}
	if p.count("compose -p "+access.ProjectName(chosen)+" ") == 0 {
		t.Fatalf("compose was not given the chosen name: %v", p.log())
	}
}

// The folder set up is the one the work entered, once: a link repointed
// to the account's own folder while Docker is asked is refused there, with
// nothing written in it; one repointed during the run leaves the setup in
// the folder entered; one that still leads where it led sets up there.
func TestSetupsWorkWritesOnlyInTheFolderItEntered(t *testing.T) {
	for _, c := range []struct {
		name, during string
		refused      bool
	}{
		{"repointed during the Docker check", "context", true},
		{"repointed during the run", "pull", false},
		{"left as it is", "", false},
	} {
		t.Run(c.name, func(t *testing.T) {
			p := newWorkProject(t)
			home := t.TempDir()
			t.Setenv("HOME", home)
			chosen := filepath.Join(t.TempDir(), "chosen")
			if err := os.Symlink(p.project, chosen); err != nil {
				t.Fatal(err)
			}
			if c.during != "" {
				p.answer(c.during+".block", "")
			}
			ended := make(chan error, 1)
			go func() {
				_, err := p.run(t.Context(), chosen)
				ended <- err
			}()
			if c.during != "" {
				p.blocked(c.during)
				next := chosen + ".next"
				if err := os.Symlink(home, next); err != nil {
					t.Fatal(err)
				}
				if err := os.Rename(next, chosen); err != nil {
					t.Fatal(err)
				}
				p.answer(c.during+".release", "")
			}
			var err error
			select {
			case err = <-ended:
			case <-time.After(20 * time.Second):
				t.Fatal("setup did not end")
			}
			// The account's own CLI settings are init's to write there;
			// nothing of the folder's is.
			var written []string
			walkErr := filepath.WalkDir(home, func(path string, _ os.DirEntry, err error) error {
				if rel, _ := filepath.Rel(home, path); rel != "." && rel != ".cyfr" && rel != filepath.Join(".cyfr", "config.json") {
					written = append(written, rel)
				}
				return err
			})
			if walkErr != nil || len(written) != 0 {
				t.Fatalf("setup wrote %v in the account's own folder (%v); it answered %v", written, walkErr, err)
			}
			if c.refused {
				if err == nil || !strings.Contains(err.Error(), "choose a folder inside it") || p.starts() != 0 || p.count("pull ") != 0 {
					t.Fatalf("it answered %v after %v", err, p.log())
				}
				if _, statErr := os.Stat(filepath.Join(p.project, ".env")); !errors.Is(statErr, os.ErrNotExist) {
					t.Fatalf("it wrote .env in the folder the link left (%v)", statErr)
				}
				return
			}
			if err != nil || p.starts() != 1 {
				t.Fatalf("it answered %v after %d starts", err, p.starts())
			}
			if token, _ := parseEnvFile(readEnv(t, p.project)).value(setupTokenVar); len(token) != 64 {
				t.Fatal("the folder entered has no setup token")
			}
		})
	}
}

// The run's start, through the real engine and the real Compose, is in
// the folder the work entered: a link repointed once Compose began to
// read the configuration leads nothing there, and the project keeps the
// name it was chosen by.
func TestSetupsStartRunsInTheFolderItEnteredThroughTheRealEngine(t *testing.T) {
	requireCompose(t)
	real, err := exec.LookPath("docker")
	if err != nil {
		t.Skip("no docker")
	}
	p := newWorkProject(t)
	t.Setenv(workRealEngine, real)
	other := t.TempDir()
	chosen := filepath.Join(t.TempDir(), "chosen")
	if err := os.Symlink(p.project, chosen); err != nil {
		t.Fatal(err)
	}
	var stack strings.Builder
	for _, service := range []string{"cyfr", "locus", "locus-guard"} {
		fmt.Fprintf(&stack, `{"name":"chosen-%s-1","service":%q,"state":"running"}`+"\n", service, service)
	}
	p.answer("stack.out", stack.String())
	p.answer("inspect.out", `{"Status":"running","ExitCode":0,"Health":{"Status":"healthy"}}`)
	p.answer("config.block", "")
	ended := make(chan error, 1)
	go func() {
		_, err := p.run(t.Context(), chosen)
		ended <- err
	}()
	p.blocked("config")
	next := chosen + ".next"
	if err := os.Symlink(other, next); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(next, chosen); err != nil {
		t.Fatal(err)
	}
	p.answer("config.release", "")
	select {
	case err = <-ended:
	case <-time.After(60 * time.Second):
		t.Fatalf("setup did not end: %q", p.log())
	}
	if entries, readErr := os.ReadDir(other); readErr != nil || len(entries) != 0 {
		t.Fatalf("the start wrote %v where the link led afterwards (%v); it answered %v", entries, readErr, err)
	}
	if err != nil || p.count("compose -p chosen ") == 0 {
		t.Fatalf("the start answered %v, its calls %q", err, p.log())
	}
	// Every call from the folder's entry on, the check of Docker before
	// it aside, ran in the folder entered.
	raw, _ := os.ReadFile(filepath.Join(p.fake, "cwd"))
	real, _ = filepath.EvalSymlinks(p.project)
	for _, line := range strings.Split(strings.TrimSpace(string(raw)), "\n") {
		if call, dir, _ := strings.Cut(line, " "); call != "context" && call != "info" && dir != real {
			t.Fatalf("docker %s ran in %s, not the folder entered %s", call, dir, real)
		}
	}
	if _, statErr := os.Stat(filepath.Join(p.project, ".cyfr")); statErr != nil {
		t.Fatalf("nothing of the start is in the folder entered (%v)", statErr)
	}
}

// A daemon's own error, its client's API version refused, is said in its
// words through the machine's real asking, and offers no installation.
func TestADaemonsOwnErrorOffersNoInstallation(t *testing.T) {
	bin := t.TempDir()
	if err := os.WriteFile(filepath.Join(bin, "docker"), []byte("#!/bin/sh\nprintf '%s\\n' 'Error response from daemon: client API version is too new' >&2\nexit 1\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin)
	saved := machine
	t.Cleanup(func() { machine = saved })
	machine.reachable, machine.refusal = realMachine.reachable, realMachine.refusal
	if ready, why, fixable := dockerReady(t.Context()); ready || fixable || why != "Docker's daemon refused this account: client API version is too new" {
		t.Fatalf("ready %v, %q, offers a remedy %v", ready, why, fixable)
	}
}

// With no sg, a stale group over a Docker whose endpoint is another
// computer's, refused there, is no missing login.
func TestNoSgOverAnotherComputersDockerIsNoMissingLogin(t *testing.T) {
	bin := t.TempDir()
	if err := os.WriteFile(filepath.Join(bin, "docker"), []byte("#!/bin/sh\nprintf '%s\\n' 'permission denied while trying to connect to the docker API at tcp://192.0.2.1:2375' >&2\nexit 1\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin)
	saved, savedSg := machine, sgProgram
	t.Cleanup(func() { machine, sgProgram = saved, savedSg })
	sgProgram = filepath.Join(t.TempDir(), "no-sg")
	machine.reachable, machine.refusal = realMachine.reachable, realMachine.refusal
	machine.dockerHere = func(context.Context) (bool, error) { return false, nil }
	machine.groups = func(_ context.Context, account string) []string {
		if account != "" {
			return []string{dockerGroup}
		}
		return nil
	}
	_, err := continueWithGroup(t.Context(), continuation{run: []string{"init"}, said: []string{"init"}}, "ada", io.Discard, io.Discard)
	if err == nil || strings.Contains(err.Error(), loginAgain) || !strings.Contains(err.Error(), "another computer") {
		t.Fatalf("continuing with the group said %v", err)
	}
}

// A Docker check given up on once Docker was asked says so: Docker did not
// answer in time, not that it was never asked.
func TestADockerCheckEndedOnceDockerWasAskedSaysSo(t *testing.T) {
	p := newWorkProject(t)
	p.answer("info.block", "")
	t.Cleanup(func() { p.answer("info.release", "") })
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	checked := make(chan desktop.DockerAnswer, 1)
	go func() { checked <- dockerCheck(ctx, shell.NewWork(ctx)) }()
	p.blocked("info")
	cancel()
	select {
	case got := <-checked:
		if got.Sentence != "Docker did not answer before the check ended" || got.Ready {
			t.Fatalf("the check ended once Docker was asked answered %+v", got)
		}
	case <-time.After(20 * time.Second):
		t.Fatal("the check given up on did not answer")
	}
}

// A start that fails says why, and asked again it starts with what was
// written.
func TestSetupsWorkStartsAgainAfterAFailedStart(t *testing.T) {
	p := newWorkProject(t)
	p.answer("up.exit", "1")
	if _, err := p.run(t.Context(), p.project); err == nil || !strings.Contains(err.Error(), "did not become healthy") {
		t.Fatalf("the failed start answered %v", err)
	}
	env := readEnv(t, p.project)
	if err := os.Remove(filepath.Join(p.fake, "up.exit")); err != nil {
		t.Fatal(err)
	}
	if steps, err := p.run(t.Context(), p.project); err != nil || !slices.Equal(steps, []string{"start"}) || readEnv(t, p.project) != env {
		t.Fatalf("asked again it answered %v after %v", err, steps)
	}
}

// A cancel ends what hangs before the start and starts nothing. A start
// once begun runs to its end, and what asked waits for it.
func TestSetupsWorkCancelled(t *testing.T) {
	for _, c := range []struct {
		during    string
		wroteEnv  bool
		finishing bool
	}{
		{during: "info"},
		{during: "context"},
		{during: "pull", wroteEnv: true},
		{during: "up", wroteEnv: true, finishing: true},
	} {
		t.Run(c.during, func(t *testing.T) {
			p := newWorkProject(t)
			p.answer(c.during+".block", "")
			ctx, cancel := context.WithCancel(t.Context())
			defer cancel()
			ended := make(chan error, 1)
			go func() {
				_, err := p.run(ctx, p.project)
				ended <- err
			}()
			pid := p.blocked(c.during)
			cancel()
			if c.finishing {
				select {
				case err := <-ended:
					t.Fatalf("the start was not waited for: %v", err)
				case <-time.After(500 * time.Millisecond): // sleep-ok: the window a cancelled start must outlive
				}
				p.answer(c.during+".release", "")
			}
			var err error
			select {
			case err = <-ended:
			case <-time.After(20 * time.Second):
				p.answer(c.during+".release", "")
				t.Fatal("the cancel did not end it")
			}
			if c.finishing {
				if err != nil || !p.has("up.ended") || p.starts() != 1 {
					t.Fatalf("the start ended with %v, finished %v", err, p.has("up.ended"))
				}
			} else {
				if err == nil || !strings.Contains(err.Error(), "stopped before CYFR was started") || p.starts() != 0 {
					t.Fatalf("the cancel answered %v after %d starts", err, p.starts())
				}
				p.await("the docker that hung to be gone", func() bool { return syscall.Kill(pid, 0) != nil })
			}
			if _, err := os.Stat(filepath.Join(p.project, ".env")); (err == nil) != c.wroteEnv {
				t.Fatalf(".env written: %v, want %v", err == nil, c.wroteEnv)
			}
			if c.during == "pull" && p.count("pull ") != 1 {
				t.Fatalf("it went on pulling after the cancel: %v", p.log())
			}
		})
	}
}

// A probe or a reading that hangs is not waited for past its caller's
// end, and the docker it waited on ends with it.
func TestSetupsWorkIsNotWaitedForPastItsCaller(t *testing.T) {
	for verb, key := range map[string]string{workProbe: "info", workLook: "context"} {
		t.Run(verb, func(t *testing.T) {
			p := newWorkProject(t)
			args := []string{verb}
			if verb == workLook {
				if _, err := p.run(t.Context(), p.project); err != nil {
					t.Fatal(err)
				}
				args = append(args, p.project)
			}
			p.answer(key+".block", "")
			ctx, cancel := context.WithCancel(t.Context())
			defer cancel()
			ended := make(chan error, 1)
			go func() {
				_, err := setupWork(ctx, shell.NewWork(t.Context()), nil, args...)
				ended <- err
			}()
			pid := p.blocked(key)
			cancel()
			select {
			case err := <-ended:
				if !errors.Is(err, context.Canceled) {
					t.Fatalf("it answered %v", err)
				}
			case <-time.After(20 * time.Second):
				p.answer(key+".release", "")
				t.Fatal("it was waited for")
			}
			p.await("the docker that hung to be gone", func() bool { return syscall.Kill(pid, 0) != nil })
		})
	}
}

// The app may die while the work runs. With its stdin still open the
// work's next step, written to nobody, kills it not. With both pipes gone
// a start begun still finishes.
func TestSetupsWorkOutlivesWhoAskedDuringAStart(t *testing.T) {
	for _, c := range []struct {
		name, during string
		stdinGone    bool
	}{
		{"nobody reads the step that begins the start", "pull", false},
		{"the app died during the start", "up", true},
	} {
		t.Run(c.name, func(t *testing.T) {
			p := newWorkProject(t)
			p.answer(c.during+".block", "")
			begin, err := preparer()(t.Context(), []string{workRun, p.project})
			if err != nil {
				t.Fatal(err)
			}
			work, err := begin()
			if err != nil {
				t.Fatal(err)
			}
			defer work.in.Close()
			p.blocked(c.during)
			if err := work.out.(io.Closer).Close(); err != nil {
				t.Fatal(err)
			}
			if c.stdinGone {
				work.in.Close()
			}
			p.answer(c.during+".release", "")
			if err := work.wait(); err != nil {
				t.Fatalf("the work ended with %v", err)
			}
			if p.starts() != 1 || p.count("compose ") == 0 {
				t.Fatalf("the start did not run: %v", p.log())
			}
		})
	}
}

// A cyfr killed while its reading's work runs (the app's 20 s departure
// deadline, a kill of the system's) ends nothing itself: the kernel closes
// the pipes it held, the work's stdin among them, which is the work's one
// cancel, and the work ends with the docker it waited on. A run's start
// goes on instead (TestSetupsWorkOutlivesWhoAskedDuringAStart).
func TestAReadingsWorkEndsWithTheCyfrThatAskedForIt(t *testing.T) {
	p := newWorkProject(t)
	p.answer("info.block", "")
	begin, err := preparer()(t.Context(), []string{workProbe})
	if err != nil {
		t.Fatal(err)
	}
	work, err := begin()
	if err != nil {
		t.Fatal(err)
	}
	pid := p.blocked("info")
	// What the kernel does for a cyfr killed: every pipe of its closed.
	work.in.Close()
	work.out.(io.Closer).Close()
	ended := make(chan error, 1)
	go func() { ended <- work.wait() }()
	select {
	case <-ended:
	case <-time.After(20 * time.Second):
		p.answer("info.release", "")
		t.Fatal("the work outlived the cyfr that asked for it")
	}
	p.await("the docker that hung to be gone", func() bool { return syscall.Kill(pid, 0) != nil })
}

// A run, setup a person started, is never ended for its caller going: past
// the bound a reading's work is killed at, its start goes on and finishes.
func TestARunOutlivesTheBoundOfAReading(t *testing.T) {
	p := newWorkProject(t)
	p.answer("up.block", "")
	ctx, cancel := context.WithCancel(t.Context())
	ran := make(chan error, 1)
	go func() {
		_, err := p.run(ctx, p.project)
		ran <- err
	}()
	pid := p.blocked("up")
	cancel()
	// sleep-ok: past the bound a reading's work is killed at, where a run must still run
	time.Sleep(workEndsWithin + time.Second)
	if syscall.Kill(pid, 0) != nil {
		t.Fatal("the run's start was ended with its caller")
	}
	p.answer("up.release", "")
	select {
	case err := <-ran:
		if err != nil {
			t.Fatalf("the run answered %v", err)
		}
	case <-time.After(20 * time.Second):
		t.Fatal("the run never finished")
	}
	if p.starts() != 1 {
		t.Fatalf("the start did not finish: %v", p.log())
	}
}

// What the launcher's environment says of a CYFR reaches neither the
// folder's .env nor Docker.
func TestSetupsWorkTakesNoSettingFromTheLauncher(t *testing.T) {
	p := newWorkProject(t)
	for name, value := range map[string]string{
		"CYFR_PORT": "4999", "CYFR_BROWSER": "domain", "COMPOSE_PROJECT_NAME": "launchers",
		setupTokenVar: strings.Repeat("cd", 32), directoryVar: "https://launcher.example",
	} {
		t.Setenv(name, value)
	}
	if _, err := p.run(t.Context(), p.project); err != nil {
		t.Fatal(err)
	}
	if port := portOf(t, p.project); port != "4000" {
		t.Errorf(".env names port %s", port)
	}
	environ, err := os.ReadFile(filepath.Join(p.fake, "environ"))
	if err != nil {
		t.Fatal(err)
	}
	for _, setting := range []string{"CYFR_PORT=", "CYFR_BROWSER=", "COMPOSE_PROJECT_NAME=launchers", setupTokenVar + "=", directoryVar + "="} {
		if strings.Contains(string(environ), setting) {
			t.Errorf("docker was given %s", setting)
		}
	}
}

// sgStandIn is sg as body has it, the group and the command it was given
// recorded in the fake's folder.
func (p workProject) sgStandIn(body string) string {
	p.t.Helper()
	path := filepath.Join(p.tools, "sg")
	script := "#!/bin/sh\nprintf '%s %s\\n' \"$1\" \"$2\" >>'" + filepath.Join(p.fake, "sg") + "'\n" + body
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		p.t.Fatal(err)
	}
	return path
}

// sg as util-linux has it, becoming the command, and as shadow has it,
// its parent, after whatever the account's shell prints as it starts.
const (
	sgBecomes = `exec /bin/sh -c "$3"` + "\n"
	sgParents = "echo 'Welcome back'\necho '{\"not\": \"a message\"}'\n" + `/bin/sh -c "$3"` + "\nexit $?\n"
)

// The docker group reaches only a new process: the work goes through sg
// where this process is older than the account's membership, on any
// Linux, and directly everywhere else.
func TestSetupsWorkReachesTheDockerGroup(t *testing.T) {
	member := []string{dockerGroup}
	for _, c := range []struct {
		name, system    string
		account, mine   []string
		noSg, throughSg bool
		body            string
	}{
		{name: "older than the group, sg becoming it", system: "linux", account: member, throughSg: true, body: sgBecomes},
		{name: "older than the group, sg its parent", system: "linux", account: member, throughSg: true, body: sgParents},
		{name: "already in the group", system: "linux", account: member, mine: member, body: sgBecomes},
		{name: "no member of the group", system: "linux", body: sgBecomes},
		{name: "no sg", system: "linux", account: member, noSg: true, body: sgBecomes},
		{name: "a Mac", system: "darwin", account: member, body: sgBecomes},
	} {
		t.Run(c.name, func(t *testing.T) {
			p := newWorkProject(t)
			machine.system = func() string { return c.system }
			machine.supported = func() bool { return false }
			machine.groups = func(_ context.Context, account string) []string {
				if account == "" {
					return c.mine
				}
				return c.account
			}
			if sg := p.sgStandIn(c.body); !c.noSg {
				sgProgram = sg
			}
			if _, err := p.run(t.Context(), p.project); err != nil {
				t.Fatal(err)
			}
			if p.starts() != 1 {
				t.Fatalf("CYFR was started %d times", p.starts())
			}
			got, err := os.ReadFile(filepath.Join(p.fake, "sg"))
			if c.throughSg && string(got) != "docker -c\n" || !c.throughSg && !errors.Is(err, os.ErrNotExist) {
				t.Fatalf("sg was given %q (%v), want it used: %v", got, err, c.throughSg)
			}
		})
	}
}

// A cancel reaches work that has sg for its parent: it is the end of
// stdin, since killing what was started would leave that work running.
func TestSetupsWorkCancelledThroughSg(t *testing.T) {
	p := newWorkProject(t)
	machine.groups = func(_ context.Context, account string) []string {
		if account == "" {
			return nil
		}
		return []string{dockerGroup}
	}
	sgProgram = p.sgStandIn(sgParents)
	p.answer("pull.block", "")
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	ended := make(chan error, 1)
	go func() {
		_, err := p.run(ctx, p.project)
		ended <- err
	}()
	pid := p.blocked("pull")
	cancel()
	select {
	case err := <-ended:
		if err == nil || !strings.Contains(err.Error(), "stopped before CYFR was started") {
			t.Fatalf("it answered %v", err)
		}
	case <-time.After(20 * time.Second):
		p.answer("pull.release", "")
		t.Fatal("the cancel did not reach the work")
	}
	p.await("the pull to be gone", func() bool { return syscall.Kill(pid, 0) != nil })
}

// Work that dies without its end is a failure, never taken for done.
func TestSetupsWorkThatDiesIsAFailure(t *testing.T) {
	p := newWorkProject(t)
	machine.groups = func(_ context.Context, account string) []string {
		if account == "" {
			return nil
		}
		return []string{dockerGroup}
	}
	sgProgram = p.sgStandIn("echo '{\"type\":\"step\",\"step\":\"start\"}'\nexit 0\n")
	steps, err := p.run(t.Context(), p.project)
	if err == nil || !strings.Contains(err.Error(), "ended before it finished") || !slices.Equal(steps, []string{"start"}) {
		t.Fatalf("it answered %v after %v", err, steps)
	}
}

// Where this process cannot reach Docker itself, older than the docker
// group or without Docker Desktop's docker on its PATH, a folder is still
// set up, opened by the app and its first person sent with the setup
// token of that folder: every reading of Docker is setup's work's.
func TestAFirstPersonWhereOnlySetupsWorkReachesDocker(t *testing.T) {
	for name, only := range map[string]func(p workProject){
		"older than the docker group": func(p workProject) {
			machine.groups = func(_ context.Context, account string) []string {
				if account == "" {
					return nil
				}
				return []string{dockerGroup}
			}
			// Docker is on sg's PATH alone.
			p.t.Setenv("PATH", p.tools)
			sgProgram = p.sgStandIn("PATH='" + p.fake + "':\"$PATH\"\nexport PATH\n" + sgBecomes)
		},
		"without Docker Desktop's docker on PATH": func(p workProject) {
			machine.system = func() string { return "darwin" }
			p.t.Setenv("PATH", p.tools)
			dockerDesktop = func(string) (string, string) { return "", p.fake }
		},
	} {
		t.Run(name, func(t *testing.T) {
			p := newWorkProject(t)
			cyfr := servingAccounts(t, "")
			home := testPrivateAt + strconv.Itoa(cyfr.port)
			var lines []string
			for _, line := range strings.Split(readShippedTemplate(t), "\n") {
				if !strings.HasPrefix(line, "CYFR_PORT=") && !strings.HasPrefix(line, directoryVar+"=") && !strings.HasPrefix(line, "CYFR_LINK_") {
					lines = append(lines, line)
				}
			}
			// The tunnel key the template carries is kept, so the CYFR set
			// up here is at the private address its accounts name.
			lines = append(lines, "CYFR_PORT="+strconv.Itoa(cyfr.port), directoryVar+"="+home, "CYFR_LINK_KEY="+testLinkKey, strings.TrimSuffix(testLinkLine, "\n"), "")
			if err := os.WriteFile(filepath.Join(p.project, ".env.example"), []byte(strings.Join(lines, "\n")), 0o644); err != nil {
				t.Fatal(err)
			}
			only(p)
			if found, err := exec.LookPath("docker"); err == nil {
				t.Fatalf("this process reaches docker at %s itself", found)
			}
			if _, err := p.run(t.Context(), p.project); err != nil {
				t.Fatal(err)
			}
			p.publishing(p.project, cyfr.port, logNotSetUp)
			a := newLocalApp(t, p.project)
			token, _ := parseEnvFile(readEnv(t, p.project)).value(setupTokenVar)
			a.setup = token
			a.open(home, home)
			a.makeAccount()
			admission, _ := helloOf(t, cyfr)["admission"].(map[string]any)
			if token == "" || admission["setup"] != token {
				t.Fatalf("the first hello carries no token of that folder's")
			}
		})
	}
}

// An interrupted pull is the last cyfr init makes, and is told as no
// image's failure.
func TestInitsPullsEndAtAnInterrupt(t *testing.T) {
	p := newWorkProject(t)
	t.Chdir(p.project)
	p.answer("pull.block", "")
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	var out, warned bytes.Buffer
	ended := make(chan error, 1)
	go func() { ended <- initProject(ctx, initOptions{}, nil, &out, &warned) }()
	p.blocked("pull")
	cancel()
	select {
	case <-ended:
	case <-time.After(20 * time.Second):
		p.answer("pull.release", "")
		t.Fatal("init did not end")
	}
	if strings.Count(out.String(), "Pulling ") != 1 || strings.Contains(warned.String(), "failed to pull") {
		t.Fatalf("after the interrupt init said:\n%s%s", out.String(), warned.String())
	}
}

// deafWork is setup's work that hears nothing: it starts a child in its
// process group, writes both pids to dir, and runs until it is killed.
func deafWork(dir string) int {
	// sleep-ok: a stand-in child that runs until its group is killed
	child := exec.Command("/bin/sleep", "300")
	if err := child.Start(); err != nil {
		return 3
	}
	pids := fmt.Sprintf("%d %d\n", os.Getpid(), child.Process.Pid)
	if err := os.WriteFile(filepath.Join(dir, "pids"), []byte(pids), 0o600); err != nil {
		return 3
	}
	signal.Ignore(syscall.SIGPIPE, syscall.SIGTERM, syscall.SIGHUP)
	// Not select {}: where nothing else of this process waits, as on macOS,
	// Go ends that at once as a deadlock (exit status 2), and the work is
	// no longer deaf.
	for {
		time.Sleep(time.Hour) // sleep-ok: the stand-in runs until its group is killed
	}
}

// gone is whether pid is no running process: none, or one only its
// parent has yet to reap.
func gone(pid int) bool {
	stat, err := os.ReadFile(fmt.Sprintf("/proc/%d/stat", pid))
	if err != nil {
		return syscall.Kill(pid, 0) != nil
	}
	_, after, _ := strings.Cut(string(stat), ") ")
	return strings.HasPrefix(after, "Z")
}

// A reading's work that hears no end of its stdin is ended within the
// bound, with everything in its process group, once the reading's caller
// went (a lock) or the CYFR was let go of (the screen's end, the app
// leaving it), the work begun before that, or as it came.
func TestAReadingsWorkDeafToItsEndIsGoneWithinTheBound(t *testing.T) {
	for name, c := range map[string]struct {
		end func(cancel func(), l desktop.Local)
		// late is whether the end comes as the work begins, under the
		// Work's lock.
		late bool
	}{
		"its caller went":             {end: func(cancel func(), _ desktop.Local) { cancel() }},
		"the CYFR was let go of":      {end: func(_ func(), l desktop.Local) { l.Work.End() }},
		"its caller went as it began": {end: func(cancel func(), _ desktop.Local) { cancel() }, late: true},
	} {
		t.Run(name, func(t *testing.T) {
			deaf := t.TempDir()
			t.Setenv(workDeaf, deaf)
			saved := startWork
			t.Cleanup(func() { startWork = saved })
			startWork = nil
			entered := make(chan struct{}, 1)
			if c.late {
				prepare := preparer()
				startWork = func(ctx context.Context, args []string) (workBegin, error) {
					begin, err := prepare(ctx, args)
					if err != nil {
						return nil, err
					}
					return func() (*workProcess, error) {
						w, err := begin()
						entered <- struct{}{}
						return w, err
					}, nil
				}
			}
			l, err := readLocal(shell.NewWork(t.Context()), setUpFolder(t), "the test")
			if err != nil {
				t.Fatal(err)
			}
			ctx, cancel := context.WithCancel(t.Context())
			defer cancel()
			read := make(chan error, 1)
			go func() { read <- l.Answers(ctx) }()
			if c.late {
				<-entered
				c.end(cancel, l)
			}
			var pids []int
			for deadline := time.Now().Add(10 * time.Second); len(pids) < 2; {
				if time.Now().After(deadline) {
					t.Fatal("the deaf work never started")
				}
				raw, _ := os.ReadFile(filepath.Join(deaf, "pids"))
				pids = nil
				for _, f := range strings.Fields(string(raw)) {
					if pid, err := strconv.Atoi(f); err == nil {
						pids = append(pids, pid)
					}
				}
				time.Sleep(20 * time.Millisecond) // sleep-ok: polls an observable condition
			}
			ended := time.Now()
			if !c.late {
				c.end(cancel, l)
			}
			select {
			case <-read:
			case <-time.After(5 * time.Second):
				t.Fatal("the reading waited for its work")
			}
			for _, pid := range pids {
				for !gone(pid) {
					if time.Since(ended) > workEndsWithin+5*time.Second {
						t.Fatalf("process %d of the work outlived the bound", pid)
					}
					time.Sleep(50 * time.Millisecond) // sleep-ok: polls an observable condition
				}
			}
			if took := time.Since(ended); took < workEndsWithin-time.Second {
				t.Fatalf("the work was ended after %v, before its bound", took)
			}
		})
	}
}

// A process group is signalled only while its leader is unreaped, so its
// number is still the work's: a kill after wait has reaped the leader
// reaches nothing, though the group's other member lives on; a kill while
// the leader has exited, unreaped, reaches that member.
func TestAGroupIsSignalledOnlyWhileItsLeaderIsUnreaped(t *testing.T) {
	for name, reap := range map[string]bool{"reaped": true, "exited, unreaped": false} {
		t.Run(name, func(t *testing.T) {
			cmd := exec.Command("/bin/sh", "-c", "sleep 60 >/dev/null 2>&1 & echo $!")
			out, err := cmd.StdoutPipe()
			if err != nil {
				t.Fatal(err)
			}
			wait, kill, err := workGroup(cmd)
			if err != nil {
				t.Fatal(err)
			}
			raw, err := io.ReadAll(out)
			if err != nil {
				t.Fatal(err)
			}
			member, err := strconv.Atoi(strings.TrimSpace(string(raw)))
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { _ = syscall.Kill(member, syscall.SIGKILL) })
			if reap {
				if err := wait(); err != nil {
					t.Fatal(err)
				}
			} else {
				exited(cmd.Process.Pid)
				defer func() { _ = wait() }()
			}
			kill()
			// A member killed is gone once its reaper sees it: wait for
			// that, or look long enough to have seen it.
			for deadline := time.Now().Add(time.Second); !gone(member) && time.Now().Before(deadline); {
				time.Sleep(20 * time.Millisecond) // sleep-ok: polls an observable condition
			}
			if gone(member) == reap {
				t.Fatalf("leader %s: the group's member gone %t after the kill", name, gone(member))
			}
		})
	}
}

// A work that closed its stdout and lives on is killed with its group at
// the bound: the leader's exit is not taken for its end.
func TestAWorkThatClosedItsStdoutAndLivesOnIsKilledAtTheBound(t *testing.T) {
	saved := startWork
	t.Cleanup(func() { startWork = saved })
	startWork = func(context.Context, []string) (workBegin, error) {
		cmd := exec.Command("/bin/sh", "-c", "exec >&-; sleep 60")
		return func() (*workProcess, error) {
			in, err := cmd.StdinPipe()
			if err != nil {
				return nil, err
			}
			out, err := cmd.StdoutPipe()
			if err != nil {
				return nil, err
			}
			wait, kill, err := workGroup(cmd)
			if err != nil {
				return nil, err
			}
			return &workProcess{in: in, out: out, wait: wait, kill: kill}, nil
		}, nil
	}
	began := time.Now()
	_, err := setupWork(t.Context(), shell.NewWork(t.Context()), nil, workProbe)
	took := time.Since(began)
	if err == nil || !strings.Contains(err.Error(), "ended before it finished") {
		t.Fatalf("it answered %v", err)
	}
	if took < workEndsWithin-500*time.Millisecond || took > workEndsWithin+5*time.Second {
		t.Fatalf("its work ended after %v, not at the bound", took)
	}
}

// appSetup is the app's chooser over the folder the person picked: its
// Set up and start pressed, and the setup it began read to its end.
type appSetup struct {
	Folder string   `json:"folder"`
	Steps  []string `json:"steps"`
	Done   bool     `json:"done"`
	Error  string   `json:"error"`
	Seq    uint64   `json:"seq"`
}

func setUpFromTheApp(t *testing.T, svc *desktop.Service, folder string) appSetup {
	t.Helper()
	// The press says what the page shows: the time since the last lock,
	// the pick and the setup there, as the state answered them; main
	// answers the pick the page asked for.
	raw, _ := json.Marshal(map[string]any{})
	var shown struct {
		Epoch, Picks uint64
		Folder       string
		Setup        *struct{ Run uint64 }
	}
	read := func() {
		t.Helper()
		if w := chosen(svc, svc.Token, "/bootstrap/state", "application/json", string(raw)); w.Code != http.StatusOK || json.Unmarshal(w.Body.Bytes(), &shown) != nil {
			t.Fatalf("/bootstrap/state answered %d %s", w.Code, w.Body)
		}
	}
	read()
	svc.FolderPicked(desktop.Message{Type: desktop.TypeFolderPicked, Path: &folder, Epoch: shown.Epoch, Pick: shown.Picks})
	if read(); shown.Folder != folder {
		t.Fatalf("the chooser shows %s, not the folder picked %s", shown.Folder, folder)
	}
	press := map[string]any{"epoch": shown.Epoch, "picks": shown.Picks}
	if shown.Setup != nil {
		press["run"] = shown.Setup.Run
	}
	ask := func(path string, body map[string]any) appSetup {
		raw, _ := json.Marshal(body)
		var got struct {
			Setup *appSetup
			Error string
		}
		if w := chosen(svc, svc.Token, path, "application/json", string(raw)); w.Code != http.StatusOK || json.Unmarshal(w.Body.Bytes(), &got) != nil || got.Setup == nil {
			t.Fatalf("%s answered %d %s", path, w.Code, w.Body)
		}
		return *got.Setup
	}
	s := ask("/bootstrap/start", press)
	if s.Folder != folder {
		t.Fatalf("Set up and start set up %q, not the folder picked %q", s.Folder, folder)
	}
	for !s.Done && s.Error == "" {
		s = ask("/bootstrap/setup", map[string]any{"seen": s.Seq})
	}
	return s
}

// The app's Set up and start sets CYFR up in the folder the person picked
// and starts it, its steps said as they begin; the account's own folder is
// refused at the start, in setup's sentence, with nothing written, and
// Try again then sets up the next folder picked.
func TestTheAppsSetUpAndStartSetsUpTheFolderPicked(t *testing.T) {
	p := newWorkProject(t)
	svc := newDesktopService(t.Context(), t.TempDir(), "", func(desktop.Message) {})
	t.Cleanup(svc.End)
	home := t.TempDir()
	t.Setenv("HOME", home)
	refused := setUpFromTheApp(t, svc, home)
	if !strings.Contains(refused.Error, "choose a folder inside it") || refused.Done {
		t.Fatalf("the account's own folder was set up: %+v", refused)
	}
	if entries, _ := os.ReadDir(home); len(entries) != 0 || p.starts() != 0 {
		t.Fatalf("the refusal wrote %d entries and made %d starts", len(entries), p.starts())
	}
	s := setUpFromTheApp(t, svc, p.project)
	if !s.Done || !slices.Equal(s.Steps, []string{"files", "settings", "images", "start"}) || p.starts() != 1 {
		t.Fatalf("Try again answered %+v after %d starts", s, p.starts())
	}
	if _, err := os.Stat(filepath.Join(p.project, ".env")); err != nil {
		t.Fatalf("no .env in the folder picked: %v", err)
	}
}
