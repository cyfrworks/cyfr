// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"slices"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/cyfr/codex/internal/access"
)

// bootSentence is the sentence the boot refuses the .env text env with, as
// the release prints it after `[Cyfr] FATAL:`.
func bootSentence(t *testing.T, env string) string {
	t.Helper()
	values := envAssignments(writeTemp(t, ".env", env))
	_, err := access.ResolveBoot(access.BootInput{File: values, Process: values, Release: true})
	if err == nil {
		t.Fatalf("the boot accepts %q", env)
	}
	return engineFailure(err).Error()
}

// `cyfr up` refuses a .env whose access settings contradict each other with
// the boot's own sentence, under the lock, before the stack is checked or
// anything starts: a missing mode, a local home at another host, a public
// URL that is not the host's, and the compose file's assertion from .env.
func TestUpRefusesAnIncoherentEnvBeforeAnythingStarts(t *testing.T) {
	for name, env := range map[string]string{
		"a missing mode":           "CYFR_HOST=localhost\nCYFR_PORT=4000\n",
		"a local home elsewhere":   "CYFR_ACCESS=local\nCYFR_HOST=cyfr.example.com\n",
		"a public URL of another":  "CYFR_ACCESS=public\nCYFR_HOST=cyfr.example.com\nCYFR_PUBLIC_URL=https://other.example.com\n",
		"the assertion from .env":  scenarioEnv + "CYFR_LOCAL_INGRESS_ASSERTED=true\n",
		"a mode that is none":      "CYFR_ACCESS=tls\n",
		"an email for a local one": "CYFR_ACCESS=local\nCADDY_ACME_EMAIL=ops@example.com\n",
	} {
		t.Run(name, func(t *testing.T) {
			s := newUpdateScenario(t, shippedCompose(t), nil)
			s.edit(".env", env)
			want := bootSentence(t, env)
			err := runUp(context.Background(), &bytes.Buffer{})
			if err == nil || err.Error() != want {
				t.Fatalf("cyfr up answered %v, want the boot's %q", err, want)
			}
			if log := s.log(); !slices.Equal(log, []string{"ENGINE lock up", "ENGINE resume"}) {
				t.Errorf("cyfr up went on past the refusal:\n%s", strings.Join(log, "\n"))
			}
		})
	}
}

// An undeclared setting passes the access coherence check, which reads
// only access settings. The release refuses it at boot; `cyfr up` reads
// the boot's refusal from cyfr's log through the engine and prints it,
// rather than a bare failed start.
func TestUpSurfacesTheBootRefusal(t *testing.T) {
	const unknownSetting = "CYFR_UNKNOWN_TEST_SETTING"
	const fatal = "[Cyfr] FATAL: " + unknownSetting + " is not a variable this server reads: no platform setting, deployment variable or compose-only name declares it. Remove it, or use the name `.env.example` gives."
	s := newUpdateScenario(t, shippedCompose(t), nil)
	s.edit(".env", scenarioEnv+unknownSetting+"=true\n")
	s.answer("up.exit", "1")
	s.answer("logs.out", "ERROR! Config provider Config.Reader failed with:\n** (RuntimeError) "+fatal+"\n    (elixir 1.19.0) lib/config/provider.ex:137\n")
	err := runUp(context.Background(), &bytes.Buffer{})
	if err == nil || !strings.Contains(err.Error(), "cyfr refused to boot, and its log says why:\n  "+fatal) {
		t.Fatalf("cyfr up answered %v, want the boot's FATAL line", err)
	}
	want := []string{"ENGINE lock up", "ENGINE resume", "ENGINE check-stack", "ENGINE start up", profiles + "up -d", profiles + "logs --no-color --no-log-prefix --tail 200 cyfr"}
	if log := s.log(); !slices.Equal(log, want) {
		t.Errorf("cyfr up ran\n%s\nwant\n%s", strings.Join(log, "\n"), strings.Join(want, "\n"))
	}

	// A log that holds no refusal leaves the start's own failure.
	s.answer("logs.out", "cyfr is starting\n")
	err = runUp(context.Background(), &bytes.Buffer{})
	if err == nil || strings.Contains(err.Error(), "FATAL") || !strings.Contains(err.Error(), "cyfr did not become healthy") {
		t.Errorf("cyfr up answered %v", err)
	}
}

// `cyfr up` starts through the engine's one start path, under the lock,
// after the stack's check, and prints the home's address from its head; a
// start that answers a refusal, as a tailnet node that is not .env's, is
// that refusal's sentence and a failure, and a stack the check refuses
// starts nothing.
func TestUpStartsThroughTheEngine(t *testing.T) {
	s := newUpdateScenario(t, shippedCompose(t), nil)
	var out bytes.Buffer
	if err := runUp(context.Background(), &out); err != nil {
		t.Fatalf("cyfr up: %v", err)
	}
	want := []string{"ENGINE lock up", "ENGINE resume", "ENGINE check-stack", "ENGINE start up", profiles + "up -d"}
	if log := s.log(); !slices.Equal(log, want) {
		t.Errorf("cyfr up ran\n%s\nwant\n%s", strings.Join(log, "\n"), strings.Join(want, "\n"))
	}
	if !strings.Contains(out.String(), "Prism:           https://cyfr.example.com/") || strings.Contains(out.String(), "CYFR_HOST") {
		t.Errorf("cyfr up does not print the home's address:\n%s", out.String())
	}
	if holder := s.engine.held(); holder != "" {
		t.Errorf("the lock is still held, by %s", holder)
	}

	s.engine.startReceipt = startedLocalReceipt("start")
	out.Reset()
	before := len(s.log())
	err := runUp(context.Background(), &out)
	if err == nil || err.Error() != access.Refuse("tailnet_node_mismatch", mismatch()).Message() || ExitStatus(err) != exitStartedLocally {
		t.Errorf("a start on this machine only made cyfr up answer %v (exit %d)", err, ExitStatus(err))
	}
	if strings.Contains(out.String(), "started") || slices.ContainsFunc(s.log()[before:], func(line string) bool { return strings.Contains(line, " logs ") }) {
		t.Errorf("cyfr up reported a start on this machine only as a start, or read the boot's log for it:\n%s", out.String())
	}

	s.engine.startReceipt = okReceipt("start")
	refused := access.Refuse("compose_env_refused", map[string]string{"key": "COMPOSE_FILE"})
	s.engine.checkErr = refused
	before = len(s.log())
	if err := runUp(context.Background(), &bytes.Buffer{}); err == nil || err.Error() != refused.Message() {
		t.Errorf("a stack the check refuses made cyfr up answer %v", err)
	}
	if log := s.log()[before:]; slices.Contains(log, "ENGINE start up") {
		t.Errorf("cyfr up started a stack the check refused:\n%s", strings.Join(log, "\n"))
	}
}

// `cyfr down` in a directory that holds no compose file refuses, with the
// engine's own reading of the directory, that nothing was stopped and
// where to run it, and takes no lock and runs no stop: the engine names
// the stack after the directory, so a home's stack started elsewhere is
// not the one it would stop, and a stop of nothing reported as "stopped"
// is what an operator who ran it in the wrong directory would believe.
func TestDownRefusesADirectoryWithNoComposeFile(t *testing.T) {
	s := newUpdateScenario(t, shippedCompose(t), nil)
	if err := os.Remove("docker-compose.yml"); err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	err := runDown(context.Background(), &out)
	if err == nil || !strings.Contains(err.Error(), "There is no stack in this directory, so nothing was stopped: ") || !strings.Contains(err.Error(), "holds no compose file") || !strings.Contains(err.Error(), "Run 'cyfr down' in CYFR's directory") {
		t.Fatalf("cyfr down in a directory with no compose file answered %v:\n%s", err, out.String())
	}
	if strings.Contains(out.String(), "stopped") || len(s.log()) != 0 {
		t.Errorf("cyfr down in a directory with no compose file reported a stop or ran the engine:\n%s\n%s", out.String(), strings.Join(s.log(), "\n"))
	}
}

// A directory that holds two main compose files, or two override files,
// is one a start refuses to choose between, and one `cyfr down` stops
// all the same: the stop reaches the project's containers by their label
// whichever file compose would load, so a stack that ran before a second
// file was laid beside its own is not left running by its own command.
func TestDownStopsAStackWhoseComposeFilesAreAmbiguous(t *testing.T) {
	for _, extra := range []string{"compose.yaml", "docker-compose.override.yml"} {
		t.Run(extra, func(t *testing.T) {
			s := newUpdateScenario(t, shippedCompose(t), nil)
			if extra == "docker-compose.override.yml" {
				if err := os.WriteFile("compose.override.yml", []byte("services: {}\n"), 0640); err != nil {
					t.Fatal(err)
				}
			}
			if err := os.WriteFile(extra, []byte("services: {}\n"), 0640); err != nil {
				t.Fatal(err)
			}
			var out bytes.Buffer
			if err := runDown(context.Background(), &out); err != nil || !strings.Contains(out.String(), "CYFR server stopped.") {
				t.Fatalf("cyfr down beside %s answered %v:\n%s", extra, err, out.String())
			}
			if log := s.log(); !slices.Contains(log, "ENGINE stop down all=true") {
				t.Errorf("cyfr down beside %s ran no stop:\n%s", extra, strings.Join(log, "\n"))
			}
		})
	}
}

// A source checkout is a home without cyfr.yaml: README's "Prefer a source
// checkout?" starts it with `cyfr up` and no `cyfr init`, from the
// checkout's own docker-compose.yml and a .env copied from .env.example.
// `cyfr down` stops what that `cyfr up` started, as in any home.
func TestDownStopsTheSourceCheckoutUpStarted(t *testing.T) {
	s := newUpdateScenario(t, shippedCompose(t), nil)
	if err := os.Remove("cyfr.yaml"); err != nil {
		t.Fatal(err)
	}
	s.engine.startReceipt = okReceipt("start")
	var out bytes.Buffer
	if err := runUp(context.Background(), &out); err != nil {
		t.Fatalf("cyfr up in a source checkout answered %v:\n%s", err, out.String())
	}
	out.Reset()
	if err := runDown(context.Background(), &out); err != nil || !strings.Contains(out.String(), "CYFR server stopped.") {
		t.Fatalf("cyfr down in the source checkout cyfr up started answered %v:\n%s", err, out.String())
	}
	if log := s.log(); !slices.Contains(log, "ENGINE stop down all=true") {
		t.Errorf("cyfr down in the source checkout ran no stop:\n%s", strings.Join(log, "\n"))
	}
}

// `cyfr down` stops every service of the project through the engine, under
// the lock; a stop it cannot verify is access_uncertain's sentence and a
// failure, never "stopped".
func TestDownStopsEverythingUnderTheLock(t *testing.T) {
	s := newUpdateScenario(t, shippedCompose(t), nil)
	var out bytes.Buffer
	if err := runDown(context.Background(), &out); err != nil || !strings.Contains(out.String(), "CYFR server stopped.") {
		t.Fatalf("cyfr down answered %v:\n%s", err, out.String())
	}
	if log := s.log(); !slices.Equal(log, []string{"ENGINE lock down", "ENGINE resume", "ENGINE stop down all=true"}) {
		t.Errorf("cyfr down ran\n%s", strings.Join(log, "\n"))
	}
	payload := map[string]string{"observed": "caddy"}
	s.engine.stopReceipt = access.Receipt{Op: "stop", State: "accepted", Phase: "uncertain", Code: "access_uncertain", Payload: payload}
	out.Reset()
	if err := runDown(context.Background(), &out); err == nil || err.Error() != access.Refuse("access_uncertain", payload).Message() || strings.Contains(out.String(), "stopped") {
		t.Errorf("an unverified stop made cyfr down answer %v:\n%s", err, out.String())
	}
	if holder := s.engine.held(); holder != "" {
		t.Errorf("the lock is still held, by %s", holder)
	}
}

// A COMPOSE_* name in .env is refused, with its sentence, by every command
// that runs compose, before any docker call: compose would read it to
// choose the stack's files, project or services behind cyfr's back. The
// engine refuses it at recovery, under the lock, so the lock and the
// recovery are the only engine calls; init, which runs no compose, refuses
// an existing .env naming one, and `cyfr access status` shows the refusal.
func TestComposeKeysInEnvAreRefusedBeforeAnyDockerCall(t *testing.T) {
	want := access.Refuse("compose_env_refused", map[string]string{"key": "COMPOSE_PROFILES"}).Message()
	engineOnly := func(t *testing.T, name string, log []string) {
		t.Helper()
		for _, line := range log {
			if !strings.HasPrefix(line, "ENGINE lock ") && line != "ENGINE resume" {
				t.Errorf("cyfr %s ran %q before the refusal:\n%s", name, line, strings.Join(log, "\n"))
			}
		}
	}
	for name, command := range map[string]func(r *restoreScenario) error{
		"up":   func(*restoreScenario) error { return runUp(context.Background(), &bytes.Buffer{}) },
		"down": func(*restoreScenario) error { return runDown(context.Background(), &bytes.Buffer{}) },
		// The scenario's home is on the release its update installed: its
		// compose file goes back to the one before, so this update has a
		// change to make.
		"update": func(r *restoreScenario) error {
			r.edit("docker-compose.yml", string(r.compose))
			return homeStep(context.Background(), &bytes.Buffer{}, &bytes.Buffer{})
		},
		"restore": func(r *restoreScenario) error {
			return runRestore(context.Background(), r.dir, true, &bytes.Buffer{}, &bytes.Buffer{})
		},
		"access": func(*restoreScenario) error {
			return runAccess(context.Background(), access.ModeLocal, accessOptions{}, true, "", &bytes.Buffer{})
		},
		"access resume": func(*restoreScenario) error { return runAccessResume(context.Background(), &bytes.Buffer{}) },
		"init": func(*restoreScenario) error {
			return runInit(context.Background(), initOptions{noPull: true}, &bytes.Buffer{}, &bytes.Buffer{})
		},
	} {
		t.Run(name, func(t *testing.T) {
			r := newRestoreScenario(t, shippedCompose(t), nil, nil)
			r.edit(".env", scenarioEnv+"export COMPOSE_PROFILES=public,tailnet\n")
			before := read(t, filepath.Join(r.project, ".env"))
			if err := command(r); err == nil || err.Error() != want {
				t.Fatalf("cyfr %s answered %v, want %q", name, err, want)
			}
			engineOnly(t, name, r.log())
			if got := read(t, filepath.Join(r.project, ".env")); got != before {
				t.Errorf("cyfr %s changed .env:\n%s", name, got)
			}
		})
	}
	// The cyfr process prints the sentence and exits 1, from a start and
	// from recovery alike.
	t.Run("the cyfr process", func(t *testing.T) {
		r := newRestoreScenario(t, shippedCompose(t), nil, nil)
		r.edit(".env", scenarioEnv+"COMPOSE_PROFILES=public\n")
		for _, args := range [][]string{{"up"}, {"access", "--resume"}} {
			_, stderr, status := runAsCyfr(t, "plain", r.project, args...)
			if wantErr := "Error: " + access.Refuse("compose_env_refused", map[string]string{"key": "COMPOSE_PROFILES"}).Message() + "\n"; status != exitFailure || stderr != wantErr {
				t.Errorf("cyfr %v exited %d, printing %q; want exit 1 and %q", args, status, stderr, wantErr)
			}
		}
	})
	t.Run("access status", func(t *testing.T) {
		r := newRestoreScenario(t, shippedCompose(t), nil, nil)
		r.edit(".env", scenarioEnv+"COMPOSE_PROFILES: public\n")
		var out bytes.Buffer
		if err := runAccessStatus(context.Background(), &out); err != nil || !strings.Contains(out.String(), want) {
			t.Errorf("cyfr access status answered %v, printing:\n%s", err, out.String())
		}
	})
}

// Through the access engine itself: `cyfr up` on an incoherent .env answers
// the boot's sentence, and on a COMPOSE_* name in .env refuses before any
// docker call.
func TestUpRefusesThroughTheRealEngine(t *testing.T) {
	for _, c := range []struct{ name, env, want string }{
		{"a local home elsewhere", "CYFR_ACCESS=local\nCYFR_HOST=cyfr.example.com\n", ""},
		{"a missing mode", "CYFR_PORT=4000\n", ""},
		{"COMPOSE_PROFILES", "CYFR_ACCESS=local\nCOMPOSE_PROFILES=public,tailnet\n", access.Refuse("compose_env_refused", map[string]string{"key": "COMPOSE_PROFILES"}).Message()},
	} {
		t.Run(c.name, func(t *testing.T) {
			dir := t.TempDir()
			t.Chdir(dir)
			if err := os.WriteFile(".env", []byte(c.env), 0600); err != nil {
				t.Fatal(err)
			}
			want := c.want
			if want == "" {
				want = bootSentence(t, c.env)
			}
			docker := &stoppedDocker{}
			useRealEngine(t, docker)
			err := runUp(context.Background(), &bytes.Buffer{})
			if err == nil || err.Error() != want {
				t.Fatalf("cyfr up answered %v, want %q", err, want)
			}
			if c.want != "" && len(docker.calls) != 0 {
				t.Errorf("docker ran before the refusal: %v", docker.calls)
			}
		})
	}
}

// Every docker child a command starts runs through the engine's runner
// (access.Engine.Docker), under the lock with the watchdog and the
// sanitized environment, but for the one launcher listed here with its
// reason. A new exec of docker anywhere else in the commands fails here.
func TestEveryDockerCallRunsThroughTheEngine(t *testing.T) {
	allowed := map[string]string{
		// The warm pull of a new project's images, in the sequence both
		// of init's faces run: outside the lock, and a pull changes
		// nothing of the stack.
		"initProject": "init's warm pull",
	}
	sources, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	found := map[string]int{}
	fset := token.NewFileSet()
	for _, name := range sources {
		if strings.HasSuffix(name, "_test.go") {
			continue
		}
		file, err := parser.ParseFile(fset, name, nil, 0)
		if err != nil {
			t.Fatal(err)
		}
		for _, decl := range file.Decls {
			fn, ok := decl.(*ast.FuncDecl)
			if !ok || fn.Body == nil {
				continue
			}
			ast.Inspect(fn.Body, func(node ast.Node) bool {
				call, ok := node.(*ast.CallExpr)
				if !ok {
					return true
				}
				sel, ok := call.Fun.(*ast.SelectorExpr)
				if !ok || sel.Sel.Name != "Command" && sel.Sel.Name != "CommandContext" {
					return true
				}
				for _, arg := range call.Args {
					if lit, ok := arg.(*ast.BasicLit); ok && lit.Kind == token.STRING {
						if value, _ := strconv.Unquote(lit.Value); value == "docker" {
							found[fn.Name.Name]++
							if _, ok := allowed[fn.Name.Name]; !ok {
								t.Errorf("%s: %s starts docker itself, not through the engine's runner", fset.Position(call.Pos()), fn.Name.Name)
							}
						}
					}
				}
				return true
			})
		}
	}
	for fn, reason := range allowed {
		if found[fn] != 1 {
			t.Errorf("%s starts docker %d times, and the exception (%s) is for one", fn, found[fn], reason)
		}
	}
}

// runAsCyfr runs this test binary as the cyfr process (TestMain) in dir,
// args its command line and scenario how the fake engine answers each
// start and switch, and answers the process's stdout, its stderr and the
// status it exited with: Run's, the status main exits with.
func runAsCyfr(t *testing.T, scenario, dir string, args ...string) (string, string, int) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	process := exec.CommandContext(ctx, os.Args[0], args...)
	process.Dir = dir
	process.Env = append(os.Environ(), asCyfr+"="+scenario)
	var stdout, stderr bytes.Buffer
	process.Stdout, process.Stderr = &stdout, &stderr
	err := process.Run()
	status := 0
	var exit *exec.ExitError
	if errors.As(err, &exit) {
		status = exit.ExitCode()
	} else if err != nil {
		t.Fatal(err)
	}
	return stdout.String(), stderr.String(), status
}

// A start that leaves the home running on this machine only, its tailnet
// machine not ready to serve it, is no success and no failed start: the
// cyfr process prints its refusal's sentence, Prima.Refusal's word for
// word, and exits 3, from cyfr up, cyfr restore and the switch of cyfr
// access alike, a machine not .env's and HTTPS off alike; a failed start
// exits 1.
func TestStartedOnThisMachineOnlyExitsThree(t *testing.T) {
	want := "Error: " + access.Refuse("tailnet_node_mismatch", mismatch()).Message() + "\n"
	check := func(t *testing.T, name, stdout, stderr string, status int) {
		t.Helper()
		if status != exitStartedLocally || stderr != want {
			t.Errorf("cyfr %s exited %d, printing %q; want exit 3 and %q", name, status, stderr, want)
		}
		if strings.Contains(stdout, "CYFR server started") || strings.Contains(stdout, "Done.") {
			t.Errorf("cyfr %s reported a start on this machine only as a success:\n%s", name, stdout)
		}
	}

	t.Run("up", func(t *testing.T) {
		s := newUpdateScenario(t, shippedCompose(t), nil)
		stdout, stderr, status := runAsCyfr(t, "started-local", s.project, "up")
		check(t, "up", stdout, stderr, status)
		if _, stderr, status := runAsCyfr(t, "failed-start", s.project, "up"); status != exitFailure || !strings.Contains(stderr, "cyfr did not become healthy") {
			t.Errorf("a failed start made cyfr up exit %d, printing %q; want exit 1", status, stderr)
		}
		// Every start on this machine only exits 3 by its outcome, its own
		// refusal's sentence printed: here the tailnet's HTTPS is off.
		https := "Error: " + access.Refuse("tailnet_https_off", httpsOff()).Message() + "\n"
		if _, stderr, status := runAsCyfr(t, "https-off", s.project, "up"); status != exitStartedLocally || stderr != https {
			t.Errorf("a start with the tailnet's HTTPS off made cyfr up exit %d, printing %q; want exit 3 and %q", status, stderr, https)
		}
	})
	t.Run("restore", func(t *testing.T) {
		r := newRestoreScenario(t, shippedCompose(t), nil, nil)
		stdout, stderr, status := runAsCyfr(t, "started-local", r.project, "restore", r.dir)
		check(t, "restore", stdout, stderr, status)
		if !strings.Contains(stdout, "Declared restore "+testRestored) {
			t.Errorf("cyfr restore does not say the restore is declared:\n%s", stdout)
		}
	})
	t.Run("access", func(t *testing.T) {
		newAccessProject(t)
		dir, err := os.Getwd()
		if err != nil {
			t.Fatal(err)
		}
		stdout, stderr, status := runAsCyfr(t, "started-local", dir, "access", "tailnet", "--yes")
		check(t, "access tailnet", stdout, stderr, status)
		if !strings.Contains(stdout, "This changes how CYFR is reached:") {
			t.Errorf("cyfr access tailnet showed no change before making it:\n%s", stdout)
		}
		// Recovery's start is a start path too: a switch it finished on
		// this machine only exits 3.
		stdout, stderr, status = runAsCyfr(t, "resumed-local", dir, "access", "--resume")
		check(t, "access --resume", stdout, stderr, status)
		if !strings.Contains(stdout, "Recovered: ") {
			t.Errorf("cyfr access --resume does not report the recovered change:\n%s", stdout)
		}
	})
}

// A hangup, the terminal cyfr runs in closing, ends cyfr as an interrupt
// does: a join waiting for its approval is cancelled, through the engine,
// and cyfr exits 1 with tailnet_join_cancelled's sentence.
func TestAHangupCancelsAWaitingJoin(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Windows sends no SIGHUP")
	}
	newAccessProject(t)
	dir, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	logDir := t.TempDir()
	process := exec.Command(os.Args[0], "access", "tailnet", "--yes")
	process.Dir = dir
	process.Env = append(os.Environ(), asCyfr+"=waiting-join", "FAKE_DOCKER_DIR="+logDir)
	stdout, err := process.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	var stderr bytes.Buffer
	process.Stderr = &stderr
	if err := process.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = process.Process.Kill() })
	waiting := make(chan bool, 1)
	var printed bytes.Buffer
	go func() {
		lines := bufio.NewScanner(stdout)
		for lines.Scan() {
			printed.WriteString(lines.Text() + "\n")
			if strings.HasPrefix(lines.Text(), "Waiting for the approval") {
				waiting <- true
				break
			}
		}
		_, _ = io.Copy(io.Discard, stdout)
		close(waiting)
	}()
	select {
	case ok := <-waiting:
		if !ok {
			t.Fatalf("cyfr ended before its join waited:\n%s%s", printed.String(), stderr.String())
		}
	case <-time.After(time.Minute):
		t.Fatal("the join never waited for its approval")
	}
	if err := process.Process.Signal(syscall.SIGHUP); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- process.Wait() }()
	var exit *exec.ExitError
	select {
	case err := <-done:
		if !errors.As(err, &exit) || exit.ExitCode() != exitFailure {
			t.Fatalf("a hangup during a waiting join ended cyfr with %v, want exit 1", err)
		}
	case <-time.After(time.Minute):
		t.Fatal("a hangup did not end a waiting join")
	}
	if want := "Error: " + access.Refuse("tailnet_join_cancelled", nil).Message() + "\n"; stderr.String() != want {
		t.Errorf("a hangup during a waiting join printed %q, want %q", stderr.String(), want)
	}
	if log, _ := os.ReadFile(filepath.Join(logDir, "log")); !strings.Contains(string(log), "ENGINE cancel-waiting-join\n") {
		t.Errorf("the waiting join was not cancelled through the engine:\n%s", log)
	}
}

// Every stop of update's own, which restore's stop is too, closes Serve
// first (the engine's CloseServe), so no tailnet request reaches a stack
// that is going away: at each `docker compose stop` Serve's configuration
// is the empty one.
func TestUpdateClosesServeBeforeItStops(t *testing.T) {
	s := newUpdateScenario(t, shippedCompose(t), nil)
	serve := filepath.Join(s.project, ".cyfr", "tailscale-serve", "serve.json")
	if err := os.MkdirAll(filepath.Dir(serve), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(serve, []byte(`{"TCP":{"443":{"HTTPS":true}},"Web":{"${TS_CERT_DOMAIN}:443":{"Handlers":{"/":{"Proxy":"http://cyfr:4401"}}}}}`), 0644); err != nil {
		t.Fatal(err)
	}
	e, err := openEngine(".")
	if err != nil {
		t.Fatal(err)
	}
	unlock, err := e.Lock("update")
	if err != nil {
		t.Fatal(err)
	}
	defer unlock()
	stops := 0
	docker := observedDocker(func(ctx context.Context, c access.Call) (access.Result, error) {
		if slices.Contains(c.Args, "stop") {
			stops++
			if got, err := os.ReadFile(serve); err != nil || strings.TrimSpace(string(got)) != "{}" {
				t.Errorf("at docker compose stop #%d Serve was %q (%v), want {}", stops, got, err)
			}
		}
		return access.Result{}, nil
	})
	u := &updater{ctx: context.Background(), out: io.Discard, errOut: io.Discard, engine: observedEngine{e, docker},
		head: access.Head{Mode: access.ModeTailnet, Host: "cyfr.tail1234.ts.net", NodeID: "nAAAAAAAAACNTRL", PublicURL: "https://cyfr.tail1234.ts.net", Port: 4000, Profiles: []string{access.ModeTailnet}}, running: []string{"tailscale", "cyfr"}}
	if err := u.stop(); err != nil {
		t.Fatal(err)
	}
	if stops == 0 {
		t.Fatal("no docker compose stop ran")
	}
}

// A failed start can leave Serve's open configuration published (written,
// then its directory sync failed), so the stop after a failed switch
// closes Serve first as every other stop does: at its `docker compose
// stop` Serve's configuration is the empty one, and the failure is
// reported whole.
func TestUpdateClosesServeBeforeTheStopAfterAFailedStart(t *testing.T) {
	s := newUpdateScenario(t, shippedCompose(t), nil)
	serve := filepath.Join(s.project, ".cyfr", "tailscale-serve", "serve.json")
	if err := os.MkdirAll(filepath.Dir(serve), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(serve, []byte(`{"TCP":{"443":{"HTTPS":true}},"Web":{"${TS_CERT_DOMAIN}:443":{"Handlers":{"/":{"Proxy":"http://cyfr:4401"}}}}}`), 0644); err != nil {
		t.Fatal(err)
	}
	e, err := openEngine(".")
	if err != nil {
		t.Fatal(err)
	}
	unlock, err := e.Lock("update")
	if err != nil {
		t.Fatal(err)
	}
	defer unlock()
	stops := 0
	docker := observedDocker(func(ctx context.Context, c access.Call) (access.Result, error) {
		if slices.Contains(c.Args, "stop") {
			stops++
			if got, err := os.ReadFile(serve); err != nil || strings.TrimSpace(string(got)) != "{}" {
				t.Errorf("at the failure cleanup's docker compose stop Serve was %q (%v), want {}", got, err)
			}
		}
		return access.Result{}, nil
	})
	u := &updater{ctx: context.Background(), version: "0.9.0", oldRelease: "0.8.0", snapshot: "backups/snapshot", out: io.Discard, errOut: io.Discard, engine: observedEngine{e, docker},
		head: access.Head{Mode: access.ModeTailnet, Host: "cyfr.tail1234.ts.net", NodeID: "nAAAAAAAAACNTRL", PublicURL: "https://cyfr.tail1234.ts.net", Port: 4000, Profiles: []string{access.ModeTailnet}}}
	err = u.stopAfterSwitch(errors.New("Serve configuration directory sync failed"))
	want := "Release 0.9.0 did not start (Serve configuration directory sync failed); the stack is left stopped.\nThe snapshot of release 0.8.0 is backups/snapshot; restore it with:\n  cyfr restore backups/snapshot"
	if err == nil || err.Error() != want {
		t.Errorf("the failure cleanup answered %v, want %q", err, want)
	}
	if stops != 1 {
		t.Fatalf("the failure cleanup ran %d docker compose stops, want 1", stops)
	}
}

// Serve that does not close stops nothing after a failed start, since no
// stop leaves Serve's open configuration behind: no docker call runs, and
// the failure says the stack was not stopped and how to stop it.
func TestUpdateStopsNothingAfterAFailedStartWhileServeDoesNotClose(t *testing.T) {
	newUpdateScenario(t, shippedCompose(t), nil)
	e, err := openEngine(".")
	if err != nil {
		t.Fatal(err)
	}
	unlock, err := e.Lock("update")
	if err != nil {
		t.Fatal(err)
	}
	defer unlock()
	var calls [][]string
	docker := observedDocker(func(ctx context.Context, c access.Call) (access.Result, error) {
		calls = append(calls, c.Args)
		return access.Result{}, nil
	})
	u := &updater{ctx: context.Background(), version: "0.9.0", oldRelease: "0.8.0", snapshot: "backups/snapshot", out: io.Discard, errOut: io.Discard,
		engine: closeServeFails{observedEngine{e, docker}, errors.New("no space left on device")},
		head:   access.Head{Mode: access.ModeTailnet, Host: "cyfr.tail1234.ts.net", NodeID: "nAAAAAAAAACNTRL", PublicURL: "https://cyfr.tail1234.ts.net", Port: 4000, Profiles: []string{access.ModeTailnet}}}
	err = u.stopAfterSwitch(errors.New("cyfr did not become healthy"))
	want := "Release 0.9.0 did not start (cyfr did not become healthy), and Tailscale Serve could not be closed (no space left on device), so nothing was stopped and the stack may still be running with Serve open; stop it with 'cyfr down'.\nThe snapshot of release 0.8.0 is backups/snapshot; restore it with:\n  cyfr restore backups/snapshot"
	if err == nil || err.Error() != want {
		t.Errorf("the failure cleanup answered %v, want %q", err, want)
	}
	if len(calls) != 0 {
		t.Errorf("the failure cleanup ran docker with Serve not closed: %q", calls)
	}
}

// closeServeFails is an engine whose CloseServe fails with err.
type closeServeFails struct {
	observedEngine
	err error
}

func (e closeServeFails) CloseServe(ctx context.Context) error { return e.err }

// observedEngine is an engine whose docker calls run through docker.
type observedEngine struct {
	stackEngine
	docker access.Docker
}

func (e observedEngine) Docker() access.Docker { return e.docker }

// observedDocker is a docker answering each call with its function.
type observedDocker func(context.Context, access.Call) (access.Result, error)

func (f observedDocker) Run(ctx context.Context, c access.Call) (access.Result, error) {
	return f(ctx, c)
}

// tailnetDocker is a docker the real engine starts a tailnet home through:
// the configuration compose gives it is the real Docker Compose's, the
// stack starts and cyfr is healthy, and the tailscale service reports the
// machine node, id; it records each call.
type tailnetDocker struct {
	mu       sync.Mutex
	node, id string
	calls    [][]string
}

func (d *tailnetDocker) Run(ctx context.Context, c access.Call) (access.Result, error) {
	d.mu.Lock()
	d.calls = append(d.calls, c.Args)
	d.mu.Unlock()
	line := strings.Join(c.Args, " ")
	switch {
	case c.Args[0] == "compose" && slices.Contains(c.Args, "config"):
		process := exec.CommandContext(ctx, "docker", c.Args...)
		for _, entry := range os.Environ() {
			if !strings.HasPrefix(entry, "COMPOSE_") {
				process.Env = append(process.Env, entry)
			}
		}
		var stdout, stderr bytes.Buffer
		process.Stdout, process.Stderr = &stdout, &stderr
		err := process.Run()
		res := access.Result{Stdout: stdout.Bytes(), Stderr: stderr.Bytes()}
		var exit *exec.ExitError
		if errors.As(err, &exit) {
			res.ExitCode = exit.ExitCode()
			return res, fmt.Errorf("exit status %d", res.ExitCode)
		}
		return res, err
	case (c.Args[0] == "exec" || c.Args[0] == "compose" && slices.Contains(c.Args, "exec")) && strings.Contains(line, "tailscale status --json"):
		status := fmt.Sprintf(`{"BackendState":"Running","Self":{"DNSName":%q,"ID":%q},"CertDomains":[%q]}`, d.node+".", d.id, d.node)
		return access.Result{Stdout: []byte(status)}, nil
	case c.Args[0] == "ps" && strings.Contains(line, "label=com.docker.compose.project="):
		project := access.ProjectName(".")
		return access.Result{Stdout: []byte(`{"name":"` + project + `-cyfr-1","service":"cyfr","state":"running"}` + "\n" + `{"name":"` + project + `-tailscale-1","service":"tailscale","state":"running"}` + "\n")}, nil
	case c.Args[0] == "inspect":
		return access.Result{Stdout: []byte(`{"Status":"running","ExitCode":0,"Health":{"Status":"healthy"}}`)}, nil
	}
	return access.Result{}, nil
}

// newTailnetHome makes the working directory a project of the shipped
// compose file whose .env, init's, holds the tailnet head of the machine
// cyfr.tail1234.ts.net (node nAAAAAAAAACNTRL), and answers its directory.
func newTailnetHome(t *testing.T) string {
	t.Helper()
	compose := shippedCompose(t)
	dir := filepath.Join(t.TempDir(), "home")
	if err := os.Mkdir(dir, 0700); err != nil {
		t.Fatal(err)
	}
	text, _ := newEnvFromTemplate(t, "me@example.com")
	t.Chdir(dir)
	d, err := access.Derive(access.Target{Mode: access.ModeTailnet}, access.Current{Port: 4000, BuildsURL: defaultBuildsURL}, &access.Join{Name: "cyfr.tail1234.ts.net", NodeID: "nAAAAAAAAACNTRL"})
	if err != nil {
		t.Fatal(err)
	}
	env, err := access.EditEnv([]byte(text), d.Assignments, d.Removals)
	if err != nil {
		t.Fatal(err)
	}
	for name, content := range map[string][]byte{"docker-compose.yml": compose, ".env": env, "cyfr.yaml": []byte("name: test\n")} {
		if err := os.WriteFile(name, content, 0600); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

// Through the real engine and Docker Compose's own configuration: a
// tailnet home whose Serve is closed, its machine now the one .env names,
// is served on the tailnet again by `cyfr access tailnet --yes`: the switch
// of the head .env holds, its start only, opens Serve.
func TestAccessTailnetServesAClosedHomeAgainThroughTheRealEngine(t *testing.T) {
	requireCompose(t)
	newTailnetHome(t)
	before := read(t, ".env")
	serve := filepath.Join(".cyfr", "tailscale-serve", "serve.json")
	if err := os.MkdirAll(filepath.Dir(serve), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(serve, []byte("{}"), 0644); err != nil {
		t.Fatal(err)
	}
	docker := &tailnetDocker{node: "cyfr.tail1234.ts.net", id: "nAAAAAAAAACNTRL"}
	useRealEngine(t, docker)
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()
	var out bytes.Buffer
	if err := runAccess(ctx, access.ModeTailnet, accessOptions{}, true, "", &out); err != nil {
		t.Fatalf("cyfr access tailnet answered %v\n%s", err, out.String())
	}
	for _, want := range []string{"Tailscale Serve is closed, so CYFR answers on this machine only.", "Done. CYFR is reached as:\n", "  Serve: open\n"} {
		if !strings.Contains(out.String(), want) {
			t.Errorf("the reopen lacks %q:\n%s", want, out.String())
		}
	}
	if got, err := os.ReadFile(serve); err != nil || strings.TrimSpace(string(got)) == "{}" {
		t.Errorf("Serve's configuration is %q (%v), want it open", got, err)
	}
	if read(t, ".env") != before {
		t.Error("the reopen rewrote .env")
	}
	for _, call := range docker.calls {
		if slices.Contains(call, "stop") || slices.Contains(call, "down") {
			t.Errorf("the reopen stopped something: %v", call)
		}
	}
}

// Through the real engine and Docker Compose's own configuration: `cyfr up`
// of a tailnet home whose machine is another node starts the home on this
// machine only, Serve closed, and answers that refusal's sentence with
// exit status 3, never a failed start (the engine answers the receipt with
// its refusal as the error).
func TestUpStartsOnThisMachineOnlyThroughTheRealEngine(t *testing.T) {
	requireCompose(t)
	dir := newTailnetHome(t)
	docker := &tailnetDocker{node: "cyfr-1.tail1234.ts.net", id: "nBBBBBBBBBCNTRL"}
	useRealEngine(t, docker)
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()
	var out bytes.Buffer
	err := runUp(ctx, &out)
	var refusal *access.Refusal
	if !errors.As(err, &refusal) || refusal.Code != "tailnet_node_mismatch" || err.Error() != refusal.Message() || ExitStatus(err) != exitStartedLocally {
		t.Fatalf("cyfr up answered %v (exit %d), want tailnet_node_mismatch's sentence and exit 3\n%s", err, ExitStatus(err), out.String())
	}
	if serve, err := os.ReadFile(filepath.Join(".cyfr", "tailscale-serve", "serve.json")); err != nil || strings.TrimSpace(string(serve)) != "{}" {
		t.Errorf("Serve's configuration is %q (%v), want it closed", serve, err)
	}
	for _, call := range docker.calls {
		if slices.Contains(call, "logs") {
			t.Errorf("cyfr up read the boot's log for a home that started: %v", call)
		}
	}

	// The cyfr process itself, over the same engine and docker, exits 3.
	_, stderr, status := runAsCyfr(t, "real-mismatch", dir, "up")
	if want := "Error: " + refusal.Message() + "\n"; status != exitStartedLocally || stderr != want {
		t.Errorf("cyfr up exited %d, printing %q; want exit 3 and %q", status, stderr, want)
	}
}
