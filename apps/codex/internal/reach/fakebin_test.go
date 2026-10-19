// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package reach

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// fakeDockerMain is the test binary as docker: it answers one call from
// the fake model in the state file at statePath, recording the call with
// the facts only a real child shows (its environment, its process group,
// the lock's descriptor), and saves the model back. `sleep-forever PIDFILE`
// writes its pid and never ends.
func fakeDockerMain(statePath string) int {
	args := os.Args[1:]
	if len(args) == 2 && args[0] == "sleep-forever" {
		os.WriteFile(args[1], []byte(strconv.Itoa(os.Getpid())), 0o600)
		select {}
	}
	release := lockState(statePath)
	f := &fakeDocker{}
	if err := loadState(statePath, f); err != nil {
		release()
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	dir, _ := os.Getwd()
	f.dir = dir
	call := &fakeCall{Args: args, Dir: dir, OwnGroup: ownGroupNow(), LockFD: lockFDIsLock(dir)}
	for _, kv := range os.Environ() {
		name, _, _ := strings.Cut(kv, "=")
		if strings.HasPrefix(strings.ToUpper(name), "COMPOSE_") || strings.HasPrefix(name, "DOCKER_") {
			call.Env = append(call.Env, kv)
		}
	}
	if len(args) > 0 && args[0] == "attach" {
		data, _ := io.ReadAll(os.Stdin)
		call.Stdin = string(data)
	}
	if p := f.st.Pause; p != nil && !p.Done && strings.Contains(strings.Join(args, " "), p.Match) {
		p.Done = true
		saveState(statePath, f)
		release()
		os.WriteFile(p.Paused, []byte(strconv.Itoa(os.Getpid())), 0o600)
		for {
			if _, err := os.Stat(p.Release); err == nil {
				break
			}
			time.Sleep(20 * time.Millisecond)
		}
		release = lockState(statePath)
		if err := loadState(statePath, f); err != nil {
			release()
			return 1
		}
	}
	a := f.handle(call)
	saveState(statePath, f)
	release()
	os.Stdout.WriteString(a.Stdout)
	os.Stderr.WriteString(a.Stderr)
	if len(args) > 0 && args[0] == "attach" && a.Code == 0 {
		select {}
	}
	return a.Code
}

func loadState(path string, f *fakeDocker) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	return json.Unmarshal(data, &f.st)
}

func saveState(path string, f *fakeDocker) {
	data, _ := json.Marshal(f.st)
	tmp := path + ".tmp"
	os.WriteFile(tmp, data, 0o600)
	os.Rename(tmp, path)
}

// lockState takes the state file's own lock, so concurrent fake docker
// processes answer one at a time.
func lockState(path string) func() {
	for {
		f, err := os.OpenFile(path+".lock", os.O_RDWR|os.O_CREATE, 0o600)
		if err == nil {
			if busy, err := lockExclusive(f); err == nil && !busy {
				return func() { f.Close() }
			}
			f.Close()
		}
		time.Sleep(5 * time.Millisecond)
	}
}

// binaryDocker points an engine's system docker at the fake model in a
// state file: the test binary is docker, and its own watchdog.
func binaryDocker(e *Engine, statePath string) {
	sys := e.docker.(*systemDocker)
	exe, _ := os.Executable()
	sys.binary = exe
	sys.watchdog = []string{exe, "-reach.watchdog"}
	sys.environ = func() []string { return childEnv("REACH_FAKE_DOCKER=" + statePath) }
}

// childEnv is the environment of a test binary re-exec'd as a docker, a
// watchdog or a holder: this one's, plus extra, with the race detector's
// one-second sleep at exit turned off, which every exec would pay.
func childEnv(extra ...string) []string {
	race := strings.TrimSpace(os.Getenv("GORACE") + " atexit_sleep_ms=0")
	return append(append(os.Environ(), "GORACE="+race), extra...)
}

// holderMain is a cyfr command in a process of its own, its docker the
// fake model in REACH_HOLDER_STATE, else the real one: `DIR READY lock`
// takes the lock and waits; `DIR READY docker ARGS…` then runs one docker
// call through the system implementation; `DIR READY switch MODE ID`
// recovers and switches to MODE, after its preview. It writes READY once
// it holds the lock, and READY.done when its work has answered.
func holderMain(args []string) int {
	dir, ready, mode := args[0], args[1], args[2]
	e, err := Open(dir, nil)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	if state := os.Getenv("REACH_HOLDER_STATE"); state != "" {
		binaryDocker(e, state)
	} else {
		exe, _ := os.Executable()
		e.docker.(*systemDocker).watchdog = []string{exe, "-reach.watchdog"}
	}
	if _, err := e.Lock("holder"); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	os.WriteFile(ready, []byte(strconv.Itoa(os.Getpid())), 0o600)
	ctx := context.Background()
	var result string
	switch mode {
	case "lock":
		select {}
	case "docker":
		res, err := e.Docker().Run(ctx, Call{Args: args[3:], Deadline: time.Hour})
		result = fmt.Sprintf("%d %v", res.ExitCode, err)
	case "switch":
		if _, err := e.Resume(ctx); err != nil {
			result = err.Error()
			break
		}
		p, err := e.Preview(ctx, Target{Mode: args[3], Domain: os.Getenv("REACH_HOLDER_DOMAIN")}, "")
		if err != nil {
			result = err.Error()
			break
		}
		rc, err := e.Switch(ctx, SwitchRequest{ID: args[4], Target: Target{Mode: args[3], Domain: os.Getenv("REACH_HOLDER_DOMAIN")}, OldDigest: p.OldDigest, NewDigest: p.NewDigest})
		result = fmt.Sprintf("%s %s %v", rc.State, rc.Outcome, err)
	}
	os.WriteFile(ready+".done", []byte(result), 0o600)
	select {}
}

func exeOrSkip(t interface{ Skip(...any) }) string {
	exe, err := os.Executable()
	if err != nil {
		t.Skip("no executable path:", err)
	}
	return filepath.Clean(exe)
}
