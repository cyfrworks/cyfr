// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package stage

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"syscall"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

const waiterHelper = "CYFR_STAGE_WAITER_HELPER"

// The waiter passes a signal to the init it waits on alone: once it has
// reaped the init, a signal it is sent reaches no process that was given
// the init's pid since. The helper runs in a pid namespace of its own,
// where it sets the next pid, so a new process takes the reaped one's.
func TestTheWaiterNeverSignalsAPidItReaped(t *testing.T) {
	if os.Getenv(waiterHelper) == "1" {
		recycleUnderTheWaiter(t)
		return
	}
	if os.Getuid() != 0 {
		t.Skip("a pid namespace whose next pid the test sets: needs root")
	}
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	cmd := exec.Command(os.Args[0], "-test.run=^TestTheWaiterNeverSignalsAPidItReaped$", "-test.count=1", "-test.v")
	cmd.Env = append(os.Environ(), waiterHelper+"=1")
	cmd.ExtraFiles = []*os.File{r, w}
	cmd.Stdout, cmd.Stderr = &out, &out
	cmd.SysProcAttr = &syscall.SysProcAttr{
		Cloneflags:  syscall.CLONE_NEWUSER | syscall.CLONE_NEWPID | syscall.CLONE_NEWNS,
		UidMappings: []syscall.SysProcIDMap{{ContainerID: 0, HostID: 0, Size: 1}},
		GidMappings: []syscall.SysProcIDMap{{ContainerID: 0, HostID: 0, Size: 1}},
	}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	// The exit word's pipe ends when the helper closes its write end: this
	// process holds none.
	_ = r.Close()
	_ = w.Close()
	if err := cmd.Wait(); err != nil {
		t.Fatalf("%s(%v)", out.String(), err)
	}
}

// recycleUnderTheWaiter is the helper, its namespace's first process: it
// runs the waiter on a short-lived child, lets the waiter reap it, gives
// its pid to a process that records a SIGUSR1, and sends the waiter one.
func recycleUnderTheWaiter(t *testing.T) {
	// The namespace's own /proc, at the one place the space's profile lets
	// a proc be mounted, gives the namespace's next pid to set.
	proc := filepath.Join(Root, "proc")
	if err := unix.Mount("", "/", "", unix.MS_REC|unix.MS_PRIVATE, ""); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(proc, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := unix.Mount("proc", proc, "proc", 0, ""); err != nil {
		t.Fatal(err)
	}
	marks := t.TempDir()
	first := exec.Command("/bin/sh", "-c", "sleep 0.2")
	if err := first.Start(); err != nil {
		t.Fatal(err)
	}
	pid := first.Process.Pid
	os.Args = []string{"cyfr-locus", "stage", WaitArg, strconv.Itoa(pid)}
	ended := make(chan int, 1)
	go func() { ended <- Wait() }()
	deadline := time.Now().Add(5 * time.Second)
	for {
		if _, err := os.Stat(filepath.Join(proc, strconv.Itoa(pid))); os.IsNotExist(err) {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("the waiter did not reap %d", pid)
		}
		time.Sleep(10 * time.Millisecond) // sleep-ok: polls the waiter's reap of a process that ends by itself
	}
	var reused *exec.Cmd
	for try := 0; try < 20 && reused == nil; try++ {
		if err := os.WriteFile(filepath.Join(proc, "sys/kernel/ns_last_pid"), []byte(strconv.Itoa(pid-1)), 0); err != nil {
			t.Fatal(err)
		}
		c := exec.Command("/bin/sh", "-c", "trap 'echo signalled > "+marks+"/got; exit 0' USR1; echo > "+marks+"/ready; while :; do sleep 0.05; done")
		if err := c.Start(); err != nil {
			t.Fatal(err)
		}
		if c.Process.Pid == pid {
			reused = c
			break
		}
		_ = c.Process.Kill()
		_ = c.Wait()
		_ = os.Remove(filepath.Join(marks, "ready"))
	}
	if reused == nil {
		t.Fatalf("no new process took pid %d", pid)
	}
	defer func() { _ = reused.Process.Kill(); _ = reused.Wait() }()
	for deadline := time.Now().Add(5 * time.Second); ; {
		if _, err := os.Stat(filepath.Join(marks, "ready")); err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the process with the reused pid never set its trap")
		}
		time.Sleep(10 * time.Millisecond) // sleep-ok: polls the shell's own word that its trap is set
	}
	if err := unix.Kill(os.Getpid(), unix.SIGUSR1); err != nil {
		t.Fatal(err)
	}
	time.Sleep(500 * time.Millisecond) // sleep-ok: the time a passed signal takes to arrive, which this test shows does not
	if _, err := os.Stat(filepath.Join(marks, "got")); err == nil {
		t.Errorf("the waiter passed its signal to pid %d, given to another process after it reaped its init", pid)
	}
	_ = os.NewFile(4, "exit-word").Close()
	select {
	case <-ended:
	case <-time.After(5 * time.Second):
		t.Fatal("the waiter did not end once its exit word's pipe closed")
	}
}
