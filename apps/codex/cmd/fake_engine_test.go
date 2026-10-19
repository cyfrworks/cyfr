// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/cyfr/codex/internal/reach"
)

// fakeStack is what the package's tests stand in for the reach engine
// with: one project's lock, its scripted answers and what the commands
// asked of it. Every engine openEngine opens during a test shares it, so a
// second command meets the first's lock. Its docker runner runs the
// `docker` on PATH (the tests' bash fakes) as the engine's system runner
// does: in a process group of its own, every COMPOSE_* out of the
// environment. It writes each engine call it answers to the fake docker's
// log, as `ENGINE <call>`, so a test reads one order of both.
type fakeStack struct {
	t  *testing.T
	mu sync.Mutex

	holder string

	openErr                error
	resume                 []reach.Receipt
	resumeErr              error
	headErr                error
	composeErr             error
	checkErr               error
	status                 reach.Status
	cancelErr, forgetErr   error
	startReceipt           reach.Receipt
	startErr               error
	stopReceipt            reach.Receipt
	stopErr                error
	switchErr              error
	switchReceipt          *reach.Receipt
	addressChanges         []string
	join                   func(ctx context.Context, r reach.JoinRequest) (reach.Receipt, error)
	joined                 map[string]reach.Join
	switches               []reach.SwitchRequest
	joins                  []reach.JoinRequest
	joinKeys               [][]byte
	locks, starts, cancels int
}

// useFakeEngine stands a fakeStack in for the engine until t ends, and the
// terminal init and reach ask on for none.
func useFakeEngine(t *testing.T) *fakeStack {
	t.Helper()
	savedOpen, savedReceipt, savedBusy := openEngine, receiptRefusal, busyRefusal
	savedTerminal, savedInput := askTerminal, askInput
	t.Cleanup(func() {
		openEngine, receiptRefusal, busyRefusal = savedOpen, savedReceipt, savedBusy
		askTerminal, askInput = savedTerminal, savedInput
	})
	return installFakeEngine(t)
}

// installFakeEngine stands a new fakeStack in for the engine, and the
// terminal init and reach ask on for none; t, when there is one, reports
// what the fake cannot do.
func installFakeEngine(t *testing.T) *fakeStack {
	s := &fakeStack{t: t, joined: map[string]reach.Join{}, startReceipt: okReceipt("start"), stopReceipt: okReceipt("stop")}
	openEngine = func(dir string) (stackEngine, error) {
		if err := s.openErr; err != nil {
			return nil, err
		}
		if key := composeKeyInEnv(filepath.Join(dir, ".env")); key != "" {
			return nil, reach.Refuse("compose_env_refused", map[string]string{"key": key})
		}
		abs, err := filepath.Abs(dir)
		if err != nil {
			return nil, err
		}
		return &fakeEngine{s: s, dir: abs}, nil
	}
	receiptRefusal = func(r reach.Receipt) *reach.Refusal {
		if r.Code == "" {
			return nil
		}
		return reach.Refuse(r.Code, r.Payload)
	}
	busyRefusal = func(b *reach.ErrBusy) *reach.Refusal {
		return reach.Refuse("reach_busy", map[string]string{"holder": b.Holder, "pid": strconv.Itoa(b.WatchdogPID), "until": b.Until.UTC().Format(time.RFC3339)})
	}
	askTerminal = func() bool { return false }
	askInput = strings.NewReader("")
	return s
}

// mismatch is the tailnet_node_mismatch payload of a start that found the
// machine's tailnet node other than the one .env names.
func mismatch() map[string]string {
	return map[string]string{"node": "cyfr-1.tail1234.ts.net", "env": "cyfr.tail1234.ts.net"}
}

// startedLocalReceipt is a start's receipt when it started the home on
// this machine alone, the machine's tailnet node not .env's.
func startedLocalReceipt(op string) reach.Receipt {
	return reach.Receipt{RequestID: strings.Repeat("0", 32), Op: op, State: "completed", Outcome: outcomeStartedLocal, Code: "tailnet_node_mismatch", Payload: mismatch()}
}

// okReceipt is a completed operation's plain success.
func okReceipt(op string) reach.Receipt {
	return reach.Receipt{RequestID: strings.Repeat("0", 32), Op: op, State: "completed", Outcome: "ok"}
}

// composeKeyInEnv is the first COMPOSE_* name the dotenv file at path
// assigns, the one the engine's Open refuses.
func composeKeyInEnv(path string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(data), "\n") {
		if name, _, ok := strings.Cut(strings.TrimSpace(line), "="); ok && strings.HasPrefix(name, "COMPOSE_") {
			return name
		}
	}
	return ""
}

// logLine writes an engine call to the fake docker's log, when a scenario
// keeps one.
func (s *fakeStack) logLine(format string, args ...any) {
	dir := os.Getenv("FAKE_DOCKER_DIR")
	if dir == "" {
		return
	}
	f, err := os.OpenFile(filepath.Join(dir, "log"), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		if s.t != nil {
			s.t.Error(err)
		}
		return
	}
	fmt.Fprintf(f, "ENGINE "+format+"\n", args...)
	f.Close()
}

// held is who holds the lock, empty when no one does.
func (s *fakeStack) held() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.holder
}

type fakeEngine struct {
	s   *fakeStack
	dir string
}

func (e *fakeEngine) Lock(holder string) (func(), error) {
	s := e.s
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.holder != "" {
		return nil, &reach.ErrBusy{Holder: s.holder}
	}
	s.holder = holder
	s.locks++
	s.logLine("lock %s", holder)
	var once sync.Once
	return func() {
		once.Do(func() {
			s.mu.Lock()
			defer s.mu.Unlock()
			s.holder = ""
		})
	}, nil
}

func (e *fakeEngine) Resume(ctx context.Context) ([]reach.Receipt, error) {
	e.s.logLine("resume")
	return e.s.resume, e.s.resumeErr
}

func (e *fakeEngine) Docker() reach.Docker { return fakeRunner{} }

// ComposeArgs answers the selection the engine documents for h: its
// project, its materialized file, the project directory and its profiles.
func (e *fakeEngine) ComposeArgs(ctx context.Context, h reach.Head, args ...string) ([]string, error) {
	if e.s.composeErr != nil {
		return nil, e.s.composeErr
	}
	return append(composePrefixArgs(e.dir, h), args...), nil
}

// composePrefixArgs is the engine's compose selection for head h in the
// project dir.
func composePrefixArgs(dir string, h reach.Head) []string {
	digest := strings.TrimPrefix(h.Digest(), "sha256:")
	full := []string{"compose", "-p", composeProject(dir), "-f", ".cyfr/compose.resolved." + digest + ".yml", "--project-directory", "."}
	for _, p := range h.Profiles {
		full = append(full, "--profile", p)
	}
	return full
}

// Head is ResolveBoot over .env's own read, as the engine's Head is.
func (e *fakeEngine) Head() (reach.Head, error) {
	if e.s.headErr != nil {
		return reach.Head{}, e.s.headErr
	}
	env := envAssignments(filepath.Join(e.dir, ".env"))
	b, err := reach.ResolveBoot(reach.BootInput{File: env, Process: env, Release: true})
	return b.Head, err
}

// envAssignments are the names and values the dotenv file at path assigns.
func envAssignments(path string) map[string]string {
	data, _ := os.ReadFile(path)
	f := parseEnvFile(string(data))
	env := map[string]string{}
	for _, line := range f.lines {
		if name, _, ok := strings.Cut(strings.TrimLeft(line, " \t"), "="); ok && name != "" && !strings.HasPrefix(name, "#") {
			if _, seen := env[name]; !seen {
				env[name], _ = f.value(name)
			}
		}
	}
	return env
}

func (e *fakeEngine) CheckStack(ctx context.Context) error {
	e.s.logLine("check-stack")
	return e.s.checkErr
}

func (e *fakeEngine) Status(ctx context.Context) (reach.Status, error) {
	e.s.logLine("status")
	return e.s.status, nil
}

// Preview derives the target's head with reach.Derive from .env's port and
// builds URL, and for tailnet from the join joinID completed.
func (e *fakeEngine) Preview(ctx context.Context, t reach.Target, joinID string) (reach.Preview, error) {
	old, _ := e.Head()
	d, err := e.derive(t, joinID)
	if err != nil {
		return reach.Preview{}, err
	}
	p := reach.Preview{
		Old: old, New: d.Head, OldDigest: old.Digest(), NewDigest: d.Head.Digest(),
		OldWords: reach.Describe(old), NewWords: reach.Describe(d.Head),
	}
	if p.OldDigest == p.NewDigest {
		return reach.Preview{}, reach.Refuse("reach_unchanged", map[string]string{"address": p.NewWords.Address})
	}
	if p.OldWords.Address != p.NewWords.Address {
		p.AddressChanges = e.s.addressChanges
	}
	return p, nil
}

func (e *fakeEngine) derive(t reach.Target, joinID string) (reach.Derivation, error) {
	env := envAssignments(filepath.Join(e.dir, ".env"))
	cur := reach.Current{Port: 4000, BuildsURL: env[buildsURLVar]}
	if text := env["CYFR_PORT"]; text != "" {
		cur.Port, _ = strconv.Atoi(text)
	}
	var join *reach.Join
	if j, ok := e.s.joined[joinID]; ok && t.Mode == reach.ModeTailnet {
		join = &j
	}
	return reach.Derive(t, cur, join)
}

// Switch fences the request's digests and commits the head's keys to .env
// as a switch of the stopped stack does.
func (e *fakeEngine) Switch(ctx context.Context, r reach.SwitchRequest) (reach.Receipt, error) {
	s := e.s
	s.logLine("switch %s %s", r.Target.Mode, r.ID)
	s.mu.Lock()
	s.switches = append(s.switches, r)
	s.mu.Unlock()
	if s.switchErr != nil {
		return reach.Receipt{}, s.switchErr
	}
	if s.switchReceipt != nil {
		return *s.switchReceipt, nil
	}
	p, err := e.Preview(ctx, r.Target, r.JoinID)
	if err != nil {
		return reach.Receipt{}, err
	}
	if p.OldDigest != r.OldDigest || p.NewDigest != r.NewDigest {
		return reach.Receipt{RequestID: r.ID, Op: "switch", State: "rejected", Code: "reach_stale", Payload: map[string]string{"words": strings.Join(p.OldWords.Sentences(), "; ")}}, nil
	}
	d, _ := e.derive(r.Target, r.JoinID)
	path := filepath.Join(e.dir, ".env")
	data, err := os.ReadFile(path)
	if err != nil {
		return reach.Receipt{}, err
	}
	f := parseEnvFile(string(data))
	writeHead(f, d)
	if err := writeFileAtomic(path, []byte(f.String()), 0600); err != nil {
		return reach.Receipt{}, err
	}
	rec := okReceipt("switch")
	rec.RequestID, rec.FinalHead = r.ID, &d.Head
	return rec, nil
}

// Join answers what the test's join answers, a machine joined as
// cyfr.tail1234.ts.net otherwise, its auth key read whole.
func (e *fakeEngine) Join(ctx context.Context, r reach.JoinRequest) (reach.Receipt, error) {
	s := e.s
	var key []byte
	if r.AuthKey != nil {
		key, _ = io.ReadAll(r.AuthKey)
	}
	s.logLine("join %s new_node=%v key=%v", r.Hostname, r.NewNode, key != nil)
	s.mu.Lock()
	s.joins = append(s.joins, r)
	s.joinKeys = append(s.joinKeys, key)
	s.mu.Unlock()
	if s.join != nil {
		return s.join(ctx, r)
	}
	if key == nil {
		r.OnAuthURL("https://login.tailscale.com/a/approve-test")
	}
	s.joined["join-"+r.ID] = reach.Join{Name: "cyfr.tail1234.ts.net", NodeID: "nTESTNODE1CNTRL"}
	rec := okReceipt("join")
	rec.RequestID = r.ID
	rec.Payload = map[string]string{"join_id": "join-" + r.ID, "name": "cyfr.tail1234.ts.net", "node_id": "nTESTNODE1CNTRL"}
	return rec, nil
}

func (e *fakeEngine) CancelWaitingJoin(ctx context.Context) error {
	e.s.logLine("cancel-waiting-join")
	e.s.mu.Lock()
	e.s.cancels++
	e.s.mu.Unlock()
	return e.s.cancelErr
}

func (e *fakeEngine) ForgetJoin() error {
	e.s.logLine("forget-join")
	return e.s.forgetErr
}

// Start brings the head up through the fake docker, so its scripted
// answers hold the start, then answers the test's receipt.
func (e *fakeEngine) Start(ctx context.Context, cause string) (reach.Receipt, error) {
	s := e.s
	s.logLine("start %s", cause)
	s.mu.Lock()
	s.starts++
	s.mu.Unlock()
	if s.startErr != nil {
		return reach.Receipt{}, s.startErr
	}
	if h, err := e.Head(); err == nil && os.Getenv("FAKE_DOCKER_DIR") != "" {
		res, err := fakeRunner{}.Run(ctx, reach.Call{Args: append(composePrefixArgs(e.dir, h), "up", "-d"), Stdout: io.Discard, Stderr: io.Discard})
		if err := callFailure(res, err); err != nil {
			return reach.Receipt{}, fmt.Errorf("cyfr did not become healthy (docker compose up: %v)", err)
		}
	}
	return s.startReceipt, nil
}

func (e *fakeEngine) Stop(ctx context.Context, cause string, all bool) (reach.Receipt, error) {
	e.s.logLine("stop %s all=%v", cause, all)
	return e.s.stopReceipt, e.s.stopErr
}

// fakeRunner runs the `docker` on PATH as the engine's system runner runs
// docker: under ctx, in a process group of its own, with every COMPOSE_*
// taken out of the environment and DOCKER_* kept.
type fakeRunner struct{}

func (fakeRunner) Run(ctx context.Context, c reach.Call) (reach.Result, error) {
	if c.Deadline > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, c.Deadline)
		defer cancel()
	}
	cmd := exec.CommandContext(ctx, "docker", c.Args...)
	cmd.SysProcAttr = ownProcessGroup()
	cmd.WaitDelay = 10 * time.Second
	for _, entry := range os.Environ() {
		if !strings.HasPrefix(entry, "COMPOSE_") {
			cmd.Env = append(cmd.Env, entry)
		}
	}
	var stdout, stderr bytes.Buffer
	cmd.Stdin, cmd.Stdout, cmd.Stderr = c.Stdin, c.Stdout, c.Stderr
	if c.Stdout == nil {
		cmd.Stdout = &stdout
	}
	if c.Stderr == nil {
		cmd.Stderr = &stderr
	}
	err := cmd.Run()
	res := reach.Result{Stdout: stdout.Bytes(), Stderr: stderr.Bytes()}
	var exit *exec.ExitError
	if errors.As(err, &exit) && exit.ExitCode() >= 0 {
		res.ExitCode = exit.ExitCode()
		return res, nil
	}
	return res, err
}

// ownProcessGroup answers attributes that start a child in a process group
// of its own, so a terminal's ^C reaches cyfr alone. Set by field name,
// since the field is Setpgid on a Unix and CREATE_NEW_PROCESS_GROUP in
// CreationFlags on Windows.
func ownProcessGroup() *syscall.SysProcAttr {
	attr := &syscall.SysProcAttr{}
	fields := reflect.ValueOf(attr).Elem()
	if field := fields.FieldByName("Setpgid"); field.IsValid() && field.Kind() == reflect.Bool {
		field.SetBool(true)
	}
	if field := fields.FieldByName("CreationFlags"); field.IsValid() && field.Kind() == reflect.Uint32 {
		const createNewProcessGroup = 0x00000200
		field.SetUint(field.Uint() | createNewProcessGroup)
	}
	return attr
}

// stoppedDocker is a docker that answers every call at once with nothing:
// a daemon with no container of the project, which is what the engine's
// switch of a stopped stack observes. It records each call's arguments.
type stoppedDocker struct {
	mu    sync.Mutex
	calls [][]string
}

func (d *stoppedDocker) Run(ctx context.Context, c reach.Call) (reach.Result, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.calls = append(d.calls, c.Args)
	return reach.Result{}, nil
}

// useRealEngine opens the reach engine itself, over docker d (the system
// runner when nil), until t ends.
func useRealEngine(t *testing.T, d reach.Docker) {
	t.Helper()
	saved, savedTerminal := openEngine, askTerminal
	t.Cleanup(func() { openEngine, askTerminal = saved, savedTerminal })
	askTerminal = func() bool { return false }
	openEngine = func(dir string) (stackEngine, error) {
		e, err := reach.Open(dir, d)
		if err != nil {
			return nil, err
		}
		return e, nil
	}
}
