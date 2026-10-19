// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package access

import (
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

// The lock admits one holder at a time: another taker is refused at once
// with access_busy naming the holder its record describes, and takes it
// once the holder lets go.
func TestLockExcludesAnotherTaker(t *testing.T) {
	h := newHome(t)
	other, err := Open(h.dir, h.fake)
	if err != nil {
		t.Fatal(err)
	}
	_, err = other.Lock("update")
	var busy *ErrBusy
	if !errors.As(err, &busy) {
		t.Fatalf("a second taker answered %v", err)
	}
	var rec holderRecord
	if ok, err := readJSON(filepath.Join(h.dir, stateDir, holderFile), &rec); !ok || err != nil {
		t.Fatalf("the holder record reads %v, %v", ok, err)
	}
	host, _ := os.Hostname()
	if busy.PID != os.Getpid() || busy.WatchdogPID != 0 || rec.Host != host {
		t.Errorf("the refusal names %+v from %+v", busy, rec)
	}
	want := "Another cyfr command holds this home (`cyfr test on " + host + ", since " + rec.Started.UTC().Format(time.RFC3339) + "`, pid `" + strconv.Itoa(os.Getpid()) + "`). Nothing was changed. Wait until it has finished, then run this command again."
	if r := busy.Refusal(); r.Code != "access_busy" || r.Message() != want {
		t.Errorf("the refusal reads %q", r.Message())
	}
	h.unlock()
	unlock, err := other.Lock("update")
	if err != nil {
		t.Fatalf("the lock was not free after its holder let go: %v", err)
	}
	unlock()
	if _, err := os.Stat(filepath.Join(h.dir, stateDir, holderFile)); err == nil {
		t.Error("the holder record outlives its lock")
	}
}

// Of many takers at once, exactly one holds the lock.
func TestConcurrentTakersExactlyOneHolds(t *testing.T) {
	h := newHome(t)
	h.unlock()
	var wg sync.WaitGroup
	var mu sync.Mutex
	held, busy := 0, 0
	var unlocks []func()
	for range 16 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			e, err := Open(h.dir, h.fake)
			if err != nil {
				t.Error(err)
				return
			}
			unlock, err := e.Lock("racer")
			mu.Lock()
			defer mu.Unlock()
			var b *ErrBusy
			switch {
			case err == nil:
				held++
				unlocks = append(unlocks, unlock)
			case errors.As(err, &b):
				busy++
			default:
				t.Error(err)
			}
		}()
	}
	wg.Wait()
	if held != 1 || busy != 15 {
		t.Errorf("%d held the lock and %d were refused", held, busy)
	}
	for _, u := range unlocks {
		u()
	}
}

// A holder killed outright right after it took the lock leaves it free:
// the kernel releases it, and the next taker holds it.
func TestLockFreesWhenItsHolderIsKilled(t *testing.T) {
	h := newHome(t)
	h.unlock()
	ready := filepath.Join(t.TempDir(), "ready")
	cmd := exec.Command(exeOrSkip(t), "-access.holder", h.dir, ready, "lock")
	cmd.Env = childEnv()
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { cmd.Process.Kill(); cmd.Wait() })
	waitFor(t, 20*time.Second, "the holder to take the lock", func() bool { _, err := os.Stat(ready); return err == nil })
	e, _ := Open(h.dir, h.fake)
	var busy *ErrBusy
	if _, err := e.Lock("next"); !errors.As(err, &busy) || !strings.Contains(busy.Holder, "cyfr holder") {
		t.Fatalf("while the holder lives the next taker answered %v", err)
	}
	cmd.Process.Kill()
	cmd.Wait()
	unlock, err := e.Lock("next")
	if err != nil {
		t.Fatalf("after the holder was killed the next taker answered %v", err)
	}
	unlock()
}

// Every method that changes the stack refuses to run without the lock.
func TestMutatingMethodsRequireTheLock(t *testing.T) {
	h := newHome(t)
	e, _ := Open(h.dir, h.fake)
	for name, call := range map[string]func() error{
		"Resume":            func() error { _, err := e.Resume(bg); return err },
		"Switch":            func() error { _, err := e.Switch(bg, SwitchRequest{ID: id(1)}); return err },
		"Join":              func() error { _, err := e.Join(bg, JoinRequest{ID: id(1)}); return err },
		"CancelJoin":        func() error { _, err := e.CancelJoin(bg, CancelRequest{ID: id(1)}); return err },
		"Start":             func() error { _, err := e.Start(bg, "up"); return err },
		"Stop":              func() error { _, err := e.Stop(bg, "down", true); return err },
		"ForgetJoin":        func() error { return e.ForgetJoin() },
		"CancelWaitingJoin": func() error { return e.CancelWaitingJoin(bg) },
		"ComposeArgs": func() error {
			_, err := e.ComposeArgs(bg, h.head(), "ps")
			return err
		},
	} {
		if err := call(); err == nil || !strings.Contains(err.Error(), "lock is not held") {
			t.Errorf("%s without the lock answered %v", name, err)
		}
	}
	if len(h.fake.calls()) != 0 {
		t.Errorf("docker was called: %v", h.fake.calls())
	}
}

// takerResult is what a contending process reports of its one Lock.
type takerResult struct {
	Name, Message, Holder, Error string
	PID, BusyPID                 int
	Held                         bool
}

// takerMain is one process contending for the lock: `DIR ROUND NAME`.
// It writes ROUND/NAME.ready, waits for ROUND/start, takes the lock once
// and writes ROUND/NAME.json; a holder then waits for ROUND/release and
// exits holding it, so the kernel, not an unlock, releases it.
func takerMain(args []string) int {
	dir, round, name := args[0], args[1], args[2]
	e, err := Open(dir, newFakeDocker(dir, nil))
	if err != nil {
		return 1
	}
	os.WriteFile(filepath.Join(round, name+".ready"), nil, 0o600)
	for {
		if _, err := os.Stat(filepath.Join(round, "start")); err == nil {
			break
		}
		time.Sleep(time.Millisecond)
	}
	r := takerResult{Name: name, PID: os.Getpid()}
	_, err = e.Lock("taker-" + name)
	var busy *ErrBusy
	switch {
	case err == nil:
		r.Held = true
	case errors.As(err, &busy):
		r.Holder, r.BusyPID, r.Message = busy.Holder, busy.PID, busy.Refusal().Message()
	default:
		r.Error = err.Error()
	}
	data, _ := json.Marshal(r)
	tmp := filepath.Join(round, name+".tmp")
	os.WriteFile(tmp, data, 0o600)
	os.Rename(tmp, filepath.Join(round, name+".json"))
	if r.Held {
		for {
			if _, err := os.Stat(filepath.Join(round, "release")); err == nil {
				break
			}
			time.Sleep(time.Millisecond)
		}
	}
	return 0
}

// Takers in separate processes, released together, contend for one
// .cyfr/lock: in every round exactly one holds it, every other is
// refused at once with access_busy naming that holder and its pid, and
// once the holder exits the next taker holds it.
func TestLockTakersInSeparateProcesses(t *testing.T) {
	const takers, rounds = 6, 4
	h := newHome(t)
	h.unlock()
	exe := exeOrSkip(t)
	host, _ := os.Hostname()
	for round := range rounds {
		dir := filepath.Join(t.TempDir(), "round")
		os.Mkdir(dir, 0o755)
		var cmds []*exec.Cmd
		for n := range takers {
			cmd := exec.Command(exe, "-access.taker", h.dir, dir, strconv.Itoa(n))
			cmd.Env = childEnv()
			if err := cmd.Start(); err != nil {
				t.Fatal(err)
			}
			cmds = append(cmds, cmd)
		}
		t.Cleanup(func() {
			for _, c := range cmds {
				c.Process.Kill()
				c.Wait()
			}
		})
		count := func(suffix string) int {
			matches, _ := filepath.Glob(filepath.Join(dir, "*"+suffix))
			return len(matches)
		}
		waitFor(t, 60*time.Second, "every taker to be ready", func() bool { return count(".ready") == takers })
		writeFile(t, filepath.Join(dir, "start"), nil)
		waitFor(t, 30*time.Second, "every taker to answer", func() bool { return count(".json") == takers })

		var results []takerResult
		for n := range takers {
			var r takerResult
			if ok, err := readJSON(filepath.Join(dir, strconv.Itoa(n)+".json"), &r); !ok || err != nil {
				t.Fatalf("round %d: taker %d reported %v, %v", round, n, ok, err)
			}
			results = append(results, r)
		}
		holders := slices.DeleteFunc(slices.Clone(results), func(r takerResult) bool { return !r.Held })
		if len(holders) != 1 {
			t.Fatalf("round %d: %d takers hold the lock: %+v", round, len(holders), results)
		}
		winner := holders[0]
		var rec holderRecord
		readJSON(filepath.Join(h.dir, stateDir, holderFile), &rec)
		want := "Another cyfr command holds this home (`cyfr taker-" + winner.Name + " on " + host + ", since " + rec.Started.UTC().Format(time.RFC3339) + "`, pid `" + strconv.Itoa(winner.PID) + "`). Nothing was changed. Wait until it has finished, then run this command again."
		for _, r := range results {
			if r.Held {
				continue
			}
			if r.Error != "" || r.BusyPID != winner.PID || !strings.HasPrefix(r.Holder, "cyfr taker-"+winner.Name+" on ") || r.Message != want {
				t.Errorf("round %d: taker %s was refused with %+v, not naming taker %s (pid %d)", round, r.Name, r, winner.Name, winner.PID)
			}
		}

		writeFile(t, filepath.Join(dir, "release"), nil)
		for _, c := range cmds {
			if err := c.Wait(); err != nil {
				t.Errorf("round %d: a taker exited with %v", round, err)
			}
		}
		if round == rounds-1 {
			// The holder exited holding it: the next taker holds it.
			e, err := Open(h.dir, h.fake)
			if err != nil {
				t.Fatal(err)
			}
			unlock, err := e.Lock("next")
			if err != nil {
				t.Fatalf("after the holder exited the next taker answered %v", err)
			}
			unlock()
		}
	}
}

// A taker refused before the holder has written its record, or while the
// record a dead holder left is still there, reads it again and names the
// holder that has the lock: never an earlier one, never none.
func TestBusyNamesTheHolderWhoseRecordIsLate(t *testing.T) {
	h := newHome(t)
	path := filepath.Join(h.dir, stateDir, holderFile)
	live, _ := os.ReadFile(path)
	dead := exec.Command(exeOrSkip(t), "-test.run=^$")
	dead.Env = childEnv()
	if err := dead.Run(); err != nil {
		t.Fatal(err)
	}
	host, _ := os.Hostname()
	stale, _ := json.Marshal(holderRecord{Command: "old", Host: host, PID: dead.Process.Pid, Started: time.Now().UTC()})
	for name, before := range map[string][]byte{"no record yet": nil, "a dead holder's record": stale} {
		t.Run(name, func(t *testing.T) {
			if before == nil {
				os.Remove(path)
			} else {
				writeFile(t, path, before)
			}
			done := make(chan struct{})
			go func() {
				defer close(done)
				time.Sleep(50 * time.Millisecond)
				writeFile(t, path, live)
			}()
			other, _ := Open(h.dir, h.fake)
			_, err := other.Lock("next")
			<-done
			busy, ok := err.(*ErrBusy)
			if !ok || busy.PID != os.Getpid() || !strings.HasPrefix(busy.Holder, "cyfr test on ") {
				t.Errorf("the next taker was refused with %#v", err)
			}
		})
	}
}
