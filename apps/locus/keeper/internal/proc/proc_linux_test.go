// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package proc

import (
	"os"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

// started starts script under sh by Own, its input a pipe the test closes.
func started(t *testing.T, script string) (*own, *os.File) {
	t.Helper()
	null, err := os.Open(os.DevNull)
	if err != nil {
		t.Fatal(err)
	}
	defer null.Close()
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	p, err := Own("/bin/sh", []string{"sh", "-c", script}, []string{}, []uintptr{r.Fd(), null.Fd(), null.Fd()}, "/", nil)
	_ = r.Close()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = w.Close(); p.Kill(false); <-p.Done() })
	return p.(*own), w
}

func ended(t *testing.T, p Process) {
	t.Helper()
	select {
	case <-p.Done():
	case <-time.After(10 * time.Second):
		t.Fatal("the process was not reaped")
	}
}

// A process Own started is reaped by its pid and its end is its own; one
// whose end another wait took is said so, never read as an exit 0.
func TestOwnSaysAnEndAndOneAnotherWaitTook(t *testing.T) {
	p, in := started(t, "read x; exit 7")
	_ = in.Close()
	ended(t, p)
	if ws, err := p.Status(); err != nil || !ws.Exited() || ws.ExitStatus() != 7 {
		t.Fatalf("a process that exited 7 ended %v, %v", ws, err)
	}

	p, in = started(t, "read x; exit 0")
	// Own's reap waits on the lock, and another wait takes the child first.
	p.mu.Lock()
	_ = in.Close()
	var ws unix.WaitStatus
	_, err := unix.Wait4(p.pid, &ws, 0, nil)
	p.mu.Unlock()
	if err != nil {
		t.Fatal(err)
	}
	ended(t, p)
	if _, err := p.Status(); err == nil {
		t.Fatal("an end another wait took was read as the process's own")
	}
}
