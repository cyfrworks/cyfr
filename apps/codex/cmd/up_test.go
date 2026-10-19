// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bytes"
	"context"
	"errors"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/cyfr/codex/internal/reach"
)

// bootSentence is the sentence the boot refuses the .env text env with, as
// the release prints it after `[Cyfr] FATAL:`.
func bootSentence(t *testing.T, env string) string {
	t.Helper()
	values := envAssignments(writeTemp(t, ".env", env))
	_, err := reach.ResolveBoot(reach.BootInput{File: values, Process: values, Release: true})
	if err == nil {
		t.Fatalf("the boot accepts %q", env)
	}
	return engineFailure(err).Error()
}

// `cyfr up` refuses a .env whose reach settings contradict each other with
// the boot's own sentence, under the lock, before the stack is checked or
// anything starts: a missing mode, a local home at another host, a public
// URL that is not the host's, and the compose file's assertion from .env.
func TestUpRefusesAnIncoherentEnvBeforeAnythingStarts(t *testing.T) {
	for name, env := range map[string]string{
		"a missing mode":           "CYFR_HOST=localhost\nCYFR_PORT=4000\n",
		"a local home elsewhere":   "CYFR_REACH=local\nCYFR_HOST=cyfr.example.com\n",
		"a public URL of another":  "CYFR_REACH=public\nCYFR_HOST=cyfr.example.com\nCYFR_PUBLIC_URL=https://other.example.com\n",
		"the assertion from .env":  scenarioEnv + "CYFR_LOCAL_INGRESS_ASSERTED=true\n",
		"a mode that is none":      "CYFR_REACH=tls\n",
		"an email for a local one": "CYFR_REACH=local\nCADDY_ACME_EMAIL=ops@example.com\n",
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

// retiredProxySetting is the setting the proxy mode had before the reach
// mode, spelled in two so no tracked file names it whole.
const retiredProxySetting = "CYFR_" + "BEHIND_PROXY"

// A retired name, the old proxy setting's, passes the reach coherence
// check, which reads only the reach keys, and the release refuses it at
// boot as a name it does not read: the start fails, and `cyfr up` reads
// the boot's refusal from cyfr's log through the engine and prints it,
// rather than a bare failed start.
func TestUpSurfacesTheBootRefusalOfARetiredName(t *testing.T) {
	const fatal = "[Cyfr] FATAL: " + retiredProxySetting + " is not a variable this server reads: no platform setting, deployment variable or compose-only name declares it. Remove it, or use the name `.env.example` gives."
	s := newUpdateScenario(t, shippedCompose(t), nil)
	s.edit(".env", scenarioEnv+retiredProxySetting+"=true\n")
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
	if err == nil || err.Error() != reach.Refuse("tailnet_node_mismatch", mismatch()).Message() || ExitStatus(err) != exitStartedLocally {
		t.Errorf("a start on this machine only made cyfr up answer %v (exit %d)", err, ExitStatus(err))
	}
	if strings.Contains(out.String(), "started") || slices.ContainsFunc(s.log()[before:], func(line string) bool { return strings.Contains(line, " logs ") }) {
		t.Errorf("cyfr up reported a start on this machine only as a start, or read the boot's log for it:\n%s", out.String())
	}

	s.engine.startReceipt = okReceipt("start")
	refused := reach.Refuse("compose_env_refused", map[string]string{"key": "COMPOSE_FILE"})
	s.engine.checkErr = refused
	before = len(s.log())
	if err := runUp(context.Background(), &bytes.Buffer{}); err == nil || err.Error() != refused.Message() {
		t.Errorf("a stack the check refuses made cyfr up answer %v", err)
	}
	if log := s.log()[before:]; slices.Contains(log, "ENGINE start up") {
		t.Errorf("cyfr up started a stack the check refused:\n%s", strings.Join(log, "\n"))
	}
}

// `cyfr down` stops every service of the project through the engine, under
// the lock; a stop it cannot verify is reach_uncertain's sentence and a
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
	s.engine.stopReceipt = reach.Receipt{Op: "stop", State: "accepted", Phase: "uncertain", Code: "reach_uncertain", Payload: payload}
	out.Reset()
	if err := runDown(context.Background(), &out); err == nil || err.Error() != reach.Refuse("reach_uncertain", payload).Message() || strings.Contains(out.String(), "stopped") {
		t.Errorf("an unverified stop made cyfr down answer %v:\n%s", err, out.String())
	}
	if holder := s.engine.held(); holder != "" {
		t.Errorf("the lock is still held, by %s", holder)
	}
}

// A COMPOSE_* name in .env is refused, with its sentence, by every command
// that runs compose, before any docker call or the lock: compose would read
// it to choose the stack's files, project or services behind cyfr's back.
func TestComposeKeysInEnvAreRefusedBeforeAnyDockerCall(t *testing.T) {
	want := reach.Refuse("compose_env_refused", map[string]string{"key": "COMPOSE_PROFILES"}).Message()
	for name, command := range map[string]func(r *restoreScenario) error{
		"up":     func(*restoreScenario) error { return runUp(context.Background(), &bytes.Buffer{}) },
		"down":   func(*restoreScenario) error { return runDown(context.Background(), &bytes.Buffer{}) },
		"update": func(*restoreScenario) error { return runUpdate(context.Background(), &bytes.Buffer{}, &bytes.Buffer{}) },
		"restore": func(r *restoreScenario) error {
			return runRestore(context.Background(), r.dir, true, &bytes.Buffer{}, &bytes.Buffer{})
		},
		"reach": func(*restoreScenario) error {
			return runReach(context.Background(), reach.ModeLocal, reachOptions{}, true, "", &bytes.Buffer{})
		},
		"reach status": func(*restoreScenario) error { return runReachStatus(context.Background(), &bytes.Buffer{}) },
		"reach resume": func(*restoreScenario) error { return runReachResume(context.Background(), &bytes.Buffer{}) },
	} {
		t.Run(name, func(t *testing.T) {
			r := newRestoreScenario(t, shippedCompose(t), nil, nil)
			r.edit(".env", scenarioEnv+"COMPOSE_PROFILES=public,tailnet\n")
			if err := command(r); err == nil || err.Error() != want {
				t.Fatalf("cyfr %s answered %v, want %q", name, err, want)
			}
			if log := r.log(); log != nil {
				t.Errorf("cyfr %s ran docker or the engine:\n%s", name, strings.Join(log, "\n"))
			}
		})
	}
}

// Through the reach engine itself: `cyfr up` on an incoherent .env answers
// the boot's sentence, and on a COMPOSE_* name in .env refuses before any
// docker call.
func TestUpRefusesThroughTheRealEngine(t *testing.T) {
	for _, c := range []struct{ name, env, want string }{
		{"a local home elsewhere", "CYFR_REACH=local\nCYFR_HOST=cyfr.example.com\n", ""},
		{"a missing mode", "CYFR_PORT=4000\n", ""},
		{"COMPOSE_PROFILES", "CYFR_REACH=local\nCOMPOSE_PROFILES=public,tailnet\n", reach.Refuse("compose_env_refused", map[string]string{"key": "COMPOSE_PROFILES"}).Message()},
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
// (reach.Engine.Docker), under the lock with the watchdog and the
// sanitized environment, but for the one launcher listed here with its
// reason. A new exec of docker anywhere else in the commands fails here.
func TestEveryDockerCallRunsThroughTheEngine(t *testing.T) {
	allowed := map[string]string{
		// The warm pull of a new project's images: outside the lock, and
		// a pull changes nothing of the stack.
		"runInit": "init's warm pull",
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
// machine not the one .env names, is no success and no failed start: the
// cyfr process prints tailnet_node_mismatch's sentence, Prima.Refusal's
// word for word, and exits 3, from cyfr up, cyfr restore and the switch of
// cyfr reach alike; a failed start exits 1.
func TestStartedOnThisMachineOnlyExitsThree(t *testing.T) {
	want := "Error: " + reach.Refuse("tailnet_node_mismatch", mismatch()).Message() + "\n"
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
	})
	t.Run("restore", func(t *testing.T) {
		r := newRestoreScenario(t, shippedCompose(t), nil, nil)
		stdout, stderr, status := runAsCyfr(t, "started-local", r.project, "restore", r.dir)
		check(t, "restore", stdout, stderr, status)
		if !strings.Contains(stdout, "Declared restore "+testRestored) {
			t.Errorf("cyfr restore does not say the restore is declared:\n%s", stdout)
		}
	})
	t.Run("reach", func(t *testing.T) {
		newReachProject(t)
		dir, err := os.Getwd()
		if err != nil {
			t.Fatal(err)
		}
		stdout, stderr, status := runAsCyfr(t, "started-local", dir, "reach", "tailnet", "--yes")
		check(t, "reach tailnet", stdout, stderr, status)
		if !strings.Contains(stdout, "This changes how this home is reached:") {
			t.Errorf("cyfr reach tailnet showed no change before making it:\n%s", stdout)
		}
	})
}
