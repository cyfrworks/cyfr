// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build windows

package reach

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"golang.org/x/sys/windows"
)

// exited reports whether process pid has ended, waiting up to limit.
func exited(pid int, limit time.Duration) bool {
	h, err := windows.OpenProcess(windows.SYNCHRONIZE, false, uint32(pid))
	if err != nil {
		return true
	}
	defer windows.CloseHandle(h)
	ev, _ := windows.WaitForSingleObject(h, uint32(limit.Milliseconds()))
	return ev == windows.WAIT_OBJECT_0
}

func readPID(t *testing.T, path string) int {
	data, _ := os.ReadFile(path)
	pid, err := strconv.Atoi(strings.TrimSpace(string(data)))
	if err != nil {
		t.Fatalf("%s holds %q", path, data)
	}
	return pid
}

// LockFileEx refuses a second handle at once, in this process or any
// other, and frees with the handle.
func TestWindowsLockFileExFailsImmediately(t *testing.T) {
	dir := t.TempDir()
	name := filepath.Join(dir, "lock")
	a, err := os.OpenFile(name, os.O_RDWR|os.O_CREATE, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	b, err := os.OpenFile(name, os.O_RDWR, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer b.Close()
	if busy, err := lockExclusive(a); busy || err != nil {
		t.Fatalf("the first handle answered %v, %v", busy, err)
	}
	start := time.Now()
	if busy, err := lockExclusive(b); !busy || err != nil {
		t.Fatalf("the second handle answered %v, %v", busy, err)
	}
	if time.Since(start) > time.Second {
		t.Error("LockFileEx waited")
	}
	a.Close()
	if busy, err := lockExclusive(b); busy || err != nil {
		t.Fatalf("after the first handle closed the second answered %v, %v", busy, err)
	}
}

// A docker child runs in a kill-on-close Job Object: when the command
// that started it dies, however it dies, the child dies with it, so no
// orphan outlives the lock.
func TestWindowsJobKillsDockerChildrenWithTheirHolder(t *testing.T) {
	h := newHome(t)
	h.unlock()
	dir := t.TempDir()
	state := filepath.Join(dir, "docker.json")
	writeFakeState(t, state, h.fake.st)
	pidfile := filepath.Join(dir, "pid")
	ready := filepath.Join(dir, "ready")
	cmd := exec.Command(exeOrSkip(t), "-reach.holder", h.dir, ready, "docker", "sleep-forever", pidfile)
	cmd.Env = childEnv("REACH_HOLDER_STATE=" + state)
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { cmd.Process.Kill(); cmd.Wait() })
	waitFor(t, 30*time.Second, "the docker child to start", func() bool { _, err := os.Stat(pidfile); return err == nil })
	child := readPID(t, pidfile)
	if exited(child, 0) {
		t.Fatal("the docker child is not running")
	}
	cmd.Process.Kill()
	cmd.Wait()
	if !exited(child, 10*time.Second) {
		t.Error("the docker child outlived its holder")
	}
	e, _ := Open(h.dir, h.fake)
	unlock, err := e.Lock("next")
	if err != nil {
		t.Fatalf("the lock is still held: %v", err)
	}
	unlock()
}

// The deadline terminates the call's whole job.
func TestWindowsDeadlineTerminatesTheJob(t *testing.T) {
	h := newHome(t)
	h.unlock()
	state := filepath.Join(t.TempDir(), "docker.json")
	writeFakeState(t, state, h.fake.st)
	e, _ := Open(h.dir, nil)
	binaryDocker(e, state)
	unlock, err := e.Lock("test")
	if err != nil {
		t.Fatal(err)
	}
	defer unlock()
	pidfile := filepath.Join(t.TempDir(), "pid")
	_, err = e.Docker().Run(bg, Call{Args: []string{"sleep-forever", pidfile}, Deadline: 2 * time.Second})
	if !errors.Is(err, ErrDeadline) {
		t.Fatalf("the call answered %v", err)
	}
	if !exited(readPID(t, pidfile), 10*time.Second) {
		t.Error("the call's child outlived its deadline")
	}
}
