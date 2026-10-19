// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package reach

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"testing"
	"time"
)

// The test binary's other roles, chosen before the tests run: the
// watchdog the engine re-execs (`-reach.watchdog`, as cyfr's hidden
// `internal docker-run`), a lock holder in a process of its own
// (`-reach.holder`), and a docker binary answering from a state file
// (REACH_FAKE_DOCKER).
func TestMain(m *testing.M) {
	if len(os.Args) > 1 {
		switch os.Args[1] {
		case "-reach.watchdog":
			os.Exit(WatchdogMain(os.Args[2:], os.Stdin, os.Stdout, os.Stderr))
		case "-reach.holder":
			os.Exit(holderMain(os.Args[2:]))
		}
	}
	if state := os.Getenv("REACH_FAKE_DOCKER"); state != "" {
		os.Exit(fakeDockerMain(state))
	}
	os.Exit(m.Run())
}

// testHome is a project directory with the shipped compose file and
// .env.example's .env, an engine on a fake docker holding its lock.
type testHome struct {
	t      *testing.T
	dir    string
	fake   *fakeDocker
	clock  *fakeClock
	e      *Engine
	unlock func()
}

func repoFile(t testing.TB, name string) []byte {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "..", name))
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func newHome(t *testing.T) *testHome {
	t.Helper()
	dir := filepath.Join(t.TempDir(), "home")
	if err := os.Mkdir(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	writeFile(t, filepath.Join(dir, "docker-compose.yml"), repoFile(t, "docker-compose.yml"))
	writeFile(t, filepath.Join(dir, ".env"), repoFile(t, ".env.example"))
	clock := newFakeClock()
	h := &testHome{t: t, dir: dir, clock: clock, fake: newFakeDocker(dir, clock)}
	h.open()
	return h
}

// open opens a new engine on the home and takes its lock, as a new
// command would.
func (h *testHome) open() {
	h.t.Helper()
	e, err := Open(h.dir, h.fake)
	if err != nil {
		h.t.Fatal(err)
	}
	e.clock = h.clock
	unlock, err := e.Lock("test")
	if err != nil {
		h.t.Fatal(err)
	}
	h.e, h.unlock = e, unlock
	h.t.Cleanup(unlock)
}

// crash ends the engine as a killed process ends: the kernel closes the
// lock's descriptor, and nothing else is cleaned up.
func (h *testHome) crash() {
	h.e.mu.Lock()
	if h.e.lock != nil {
		h.e.lock.Close()
		h.e.lock = nil
	}
	h.e.mu.Unlock()
}

// killAt runs op until the engine reaches point, and ends it there as a
// kill would: no line after the point runs. It reports whether the point
// was reached; the home then has a new engine, as the next command.
func (h *testHome) killAt(point string, op func(e *Engine)) bool {
	h.t.Helper()
	reached := false
	h.e.hook = func(p string) {
		if p == point {
			reached = true
			runtime.Goexit()
		}
	}
	done := make(chan struct{})
	go func() {
		defer close(done)
		op(h.e)
	}()
	<-done
	h.e.hook = nil
	h.crash()
	h.open()
	return reached
}

func writeFile(t testing.TB, name string, data []byte) {
	t.Helper()
	if err := os.WriteFile(name, data, 0o600); err != nil {
		t.Fatal(err)
	}
}

func (h *testHome) env() string {
	data, err := os.ReadFile(filepath.Join(h.dir, ".env"))
	if err != nil {
		h.t.Fatal(err)
	}
	return string(data)
}

// head is .env's head now.
func (h *testHome) head() Head {
	h.t.Helper()
	got, err := h.e.Head()
	if err != nil {
		h.t.Fatalf(".env holds no head: %v", err)
	}
	return got
}

// target derives t's head from .env, as a preview does.
func (h *testHome) preview(t Target, joinID string) Preview {
	h.t.Helper()
	p, err := h.e.Preview(context.Background(), t, joinID)
	if err != nil {
		h.t.Fatalf("preview %v: %v", t, err)
	}
	return p
}

// request is a switch to t as the CLI sends it after its preview.
func (h *testHome) request(id string, t Target, joinID string) SwitchRequest {
	p := h.preview(t, joinID)
	return SwitchRequest{ID: id, Target: t, JoinID: joinID, OldDigest: p.OldDigest, NewDigest: p.NewDigest}
}

func (h *testHome) files(pattern string) []string {
	matches, _ := filepath.Glob(filepath.Join(h.dir, stateDir, pattern))
	for i, m := range matches {
		matches[i] = filepath.Base(m)
	}
	return matches
}

// assertConverged checks the home holds one coherent head: no journal,
// no materialized file, and exactly the services want running.
func (h *testHome) assertConverged(want ...string) {
	h.t.Helper()
	if _, err := os.Stat(filepath.Join(h.dir, stateDir, journalFile)); err == nil {
		data, _ := os.ReadFile(filepath.Join(h.dir, stateDir, journalFile))
		h.t.Errorf("a journal is left:\n%s", data)
	}
	if files := h.files(resolvedGlob); len(files) > 0 {
		h.t.Errorf("materialized files are left: %v", files)
	}
	if _, err := h.e.Head(); err != nil {
		h.t.Errorf(".env holds no coherent head: %v", err)
	}
	slices.Sort(want)
	if got := h.fake.runningServices(); !slices.Equal(got, want) {
		h.t.Errorf("running %v, want %v", got, want)
	}
}

// id is a request id, the n-th of a test.
func id(n int) string { return fmt.Sprintf("%032x", n) }

// localStack, publicStack and tailnetStack are the services each mode
// runs with builds on, as .env.example has them.
var (
	baseStack    = []string{"cyfr", "locus-backends", "locus-backends-guard", "locus-builds", "locus-builds-guard", "locus-runtime"}
	publicStack  = append(slices.Clone(baseStack), "caddy")
	tailnetStack = append(slices.Clone(baseStack), "tailscale")
)

// refusalCode is the code of err's refusal, "" when it carries none.
func refusalCode(err error) string {
	var r *Refusal
	if errors.As(err, &r) {
		return r.Code
	}
	return ""
}

// readState reads the binary model's state file.
func readFakeState(t testing.TB, path string) fakeState {
	t.Helper()
	var st fakeState
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(data, &st); err != nil {
		t.Fatal(err)
	}
	return st
}

func writeFakeState(t testing.TB, path string, st fakeState) {
	t.Helper()
	data, err := json.Marshal(st)
	if err != nil {
		t.Fatal(err)
	}
	writeFile(t, path, data)
}

// waitFor polls cond every 10ms until it holds or limit passes.
func waitFor(t testing.TB, limit time.Duration, what string, cond func() bool) {
	t.Helper()
	end := time.Now().Add(limit)
	for !cond() {
		if time.Now().After(end) {
			t.Fatalf("timed out after %s waiting for %s", limit, what)
		}
		time.Sleep(10 * time.Millisecond)
	}
}
