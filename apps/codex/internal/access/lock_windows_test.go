// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build windows

package access

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
	cmd := exec.Command(exeOrSkip(t), "-access.holder", h.dir, ready, "docker", "sleep-forever", pidfile)
	cmd.Env = childEnv("ACCESS_HOLDER_STATE=" + state)
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

// A record replaced while another handle reads it: os.Open holds the file
// without FILE_SHARE_DELETE, during which MoveFileEx refuses to replace
// it, so a holder writing its record while a refused taker in another
// process read it (every 5 ms for recordWait) failed to take the lock
// with "Access is denied". replaceFile tries again within replaceWait:
// while the reader's handle is open the replacement is neither answered
// nor refused, it lands once the handle closes, and a handle held past
// replaceWait is refused with the error the rename gave. The reader here
// is a handle of this process, which restricts the rename exactly as
// another process's does.
func TestReplaceFileWaitsOutAReader(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "holder")
	tmp := filepath.Join(dir, ".holder.tmp")
	if err := os.WriteFile(target, []byte("old"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(tmp, []byte("new"), 0o600); err != nil {
		t.Fatal(err)
	}
	reader, err := os.Open(target)
	if err != nil {
		t.Fatal(err)
	}
	answered := make(chan error, 1)
	go func() { answered <- replaceFile(tmp, target) }()
	select {
	case err := <-answered:
		t.Fatalf("the replacement answered %v while a reader held the file", err)
	case <-time.After(50 * time.Millisecond):
	}
	reader.Close()
	select {
	case err := <-answered:
		if err != nil {
			t.Fatalf("the replacement was refused after the reader closed: %v", err)
		}
	case <-time.After(replaceWait):
		t.Fatal("the replacement did not land within replaceWait of the reader closing")
	}
	if data, _ := os.ReadFile(target); string(data) != "new" {
		t.Fatalf("the replacement did not land: the file holds %q", data)
	}

	// A handle held past the window: refused with the rename's error, after
	// at least replaceWait.
	if err := os.WriteFile(tmp, []byte("newer"), 0o600); err != nil {
		t.Fatal(err)
	}
	held, err := os.Open(target)
	if err != nil {
		t.Fatal(err)
	}
	defer held.Close()
	started := time.Now()
	err = replaceFile(tmp, target)
	var linkErr *os.LinkError
	if !errors.As(err, &linkErr) || time.Since(started) < replaceWait {
		t.Fatalf("a handle held past replaceWait answered %v after %v", err, time.Since(started))
	}
	if data, _ := os.ReadFile(target); string(data) != "new" {
		t.Fatalf("a refused replacement changed the file to %q", data)
	}
}
