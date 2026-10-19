// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package reach

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// The lock admits one holder at a time: another taker is refused at once
// with reach_busy naming the holder its record describes, and takes it
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
	host, _ := os.Hostname()
	msg := busy.Refusal().Message()
	if busy.Refusal().Code != "reach_busy" || !strings.Contains(msg, "Another cyfr command holds this home (`cyfr test, pid ") || !strings.Contains(msg, " on "+host+", since ") {
		t.Errorf("the refusal reads %q", msg)
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
	cmd := exec.Command(exeOrSkip(t), "-reach.holder", h.dir, ready, "lock")
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
