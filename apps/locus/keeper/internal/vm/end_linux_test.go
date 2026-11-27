// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package vm

import (
	"bufio"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

// fakeMachine is a Machine whose VMM is cmd, already started, and whose
// vsock socket is a listener in its folder that the test answers as
// Firecracker's device would; its uid and gid are the test's own. Each of
// setup is applied before its waiter starts.
func fakeMachine(t *testing.T, cmd *exec.Cmd, setup ...func(*Machine)) (*Machine, net.Listener) {
	t.Helper()
	dir, err := os.MkdirTemp("", "vm-end-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	l, err := net.Listen("unix", filepath.Join(dir, "vsock.sock"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = l.Close() })
	m := &Machine{dir: dir, uid: os.Getuid(), gid: os.Getgid(), cmd: cmd, done: make(chan struct{})}
	for _, f := range setup {
		f(m)
	}
	go m.wait()
	return m, l
}

// answerEnd answers one CONNECT to EndPort as the device and the guest's
// first process would, writing answer, and then runs then.
func answerEnd(t *testing.T, l net.Listener, answer string, then func()) {
	go func() {
		conn, err := l.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		line, err := bufio.NewReader(conn).ReadString('\n')
		if err != nil || line != "CONNECT 1026\n" {
			return
		}
		_, _ = io.WriteString(conn, "OK 1073741824\n"+answer)
		then()
	}()
}

// A VMM that exited before any end was asked is its own exit, never an
// acknowledged end (the review's stand-in: an exit of 23).
func TestAVMMsOwnExitIsNotAnAcknowledgedEnd(t *testing.T) {
	cmd := exec.Command("/bin/sh", "-c", "exit 23")
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	m, _ := fakeMachine(t, cmd)
	<-m.done
	if got := m.End(time.Second); got != EndOwnExit {
		t.Fatalf("a VMM that exited 23 ended %q, not %q", got, EndOwnExit)
	}
}

// An end the guest's first process acknowledged, after which the VMM exits,
// is the acknowledged one.
func TestAnAcknowledgedEndIsSaidSo(t *testing.T) {
	cmd := exec.Command("/bin/sh", "-c", "read x")
	stdin, err := cmd.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	m, l := fakeMachine(t, cmd)
	answerEnd(t, l, EndAck, func() { _ = stdin.Close() })
	if got := m.End(5 * time.Second); got != EndAcknowledged {
		t.Fatalf("an acknowledged end was said as %q", got)
	}
}

// A VMM that exits while its end was asked but never acknowledged is its
// own exit: a guest that died as the host asked.
func TestAnUnacknowledgedEndIsTheVMMsOwnExit(t *testing.T) {
	cmd := exec.Command("/bin/sh", "-c", "read x")
	stdin, err := cmd.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	m, l := fakeMachine(t, cmd)
	answerEnd(t, l, "", func() { _ = stdin.Close() })
	if got := m.End(5 * time.Second); got != EndOwnExit {
		t.Fatalf("an unacknowledged end was said as %q", got)
	}
}

// A VMM still running past the end's bound is killed, and said so.
func TestAVMMPastItsBoundIsKilled(t *testing.T) {
	cmd := exec.Command("/bin/sh", "-c", "read x")
	stdin, err := cmd.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = stdin.Close() })
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	m, l := fakeMachine(t, cmd)
	answerEnd(t, l, EndAck, func() {})
	if got := m.End(300 * time.Millisecond); got != EndKilled {
		t.Fatalf("a VMM past its bound ended %q", got)
	}
}

// A VMM that exits by itself is cleared by its own waiter, with no End or
// Kill: its folder is gone, its hold on the device's lock released, and its
// end recorded as its own exit.
func TestAVMMsOwnExitClearsItsFolderAndItsLockByItself(t *testing.T) {
	dir := t.TempDir()
	folder := filepath.Join(dir, "machine")
	if err := os.Mkdir(folder, 0o700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "device.sqfs")
	if err := os.WriteFile(path, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := unix.Flock(int(f.Fd()), unix.LOCK_SH|unix.LOCK_NB); err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command("/bin/sh", "-c", "exit 23")
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	m, _ := fakeMachine(t, cmd, func(m *Machine) {
		m.device = &Device{Path: path, f: f}
		// The stand-in for retire: the folder's removal.
		m.clear = func() error { return os.RemoveAll(folder) }
	})
	select {
	case <-m.Done():
	case <-time.After(10 * time.Second):
		t.Fatal("a VMM that exited by itself was not cleared")
	}
	if _, err := os.Stat(folder); !os.IsNotExist(err) {
		t.Fatalf("the machine's folder is left after its VMM's own exit: %v", err)
	}
	other, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer other.Close()
	if err := unix.Flock(int(other.Fd()), unix.LOCK_EX|unix.LOCK_NB); err != nil {
		t.Fatalf("the device's lock is still held after its VMM's own exit: %v", err)
	}
	if got := m.HowEnded(); got != EndOwnExit {
		t.Fatalf("a VMM that exited by itself is recorded as %q, not %q", got, EndOwnExit)
	}
}

// Each machine is allotted a uid of its own from MachineUIDs, and one given
// back is the last to be allotted again.
func TestEachMachineIsAllottedAUIDOfItsOwn(t *testing.T) {
	a, allotted, err := takeUID(0)
	if err != nil || !allotted {
		t.Fatal(allotted, err)
	}
	b, _, err := takeUID(0)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { giveBack(b, true) })
	if a == b || !MachineUIDs.Contains(a) || !MachineUIDs.Contains(b) {
		t.Fatalf("two machines were allotted %d and %d, not two uids of %d-%d", a, b, MachineUIDs.First, MachineUIDs.Last)
	}
	giveBack(a, true)
	c, _, err := takeUID(0)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { giveBack(c, true) })
	if c == a {
		t.Fatalf("the uid %d given back was allotted again before the rest", a)
	}
}

// A person's VM runs under their disk's uid, given, which no second machine
// of this keeper takes while the first runs, and which is no allotment's:
// its end lets it go, and a uid that runs a process is refused.
func TestAPersonsVMRunsUnderItsDisksUIDAlone(t *testing.T) {
	const disk = 59998
	uid, allotted, err := takeUID(disk)
	if err != nil || uid != disk || allotted {
		t.Fatalf("a person's VM took uid %d (allotted %t): %v", uid, allotted, err)
	}
	if _, _, err := takeUID(disk); err == nil {
		t.Fatal("a second machine took the uid a first runs under")
	}
	giveBack(disk, false)
	if _, _, err := takeUID(disk); err != nil {
		t.Fatalf("a uid let go was refused: %v", err)
	}
	giveBack(disk, false)
	busy := os.Getuid()
	if busy == 0 {
		// As root, a process of a uid of the test's own.
		busy = 59997
		sleeper := exec.Command("sleep", "30")
		sleeper.SysProcAttr = &syscall.SysProcAttr{Credential: &syscall.Credential{Uid: uint32(busy), Gid: uint32(busy)}}
		if err := sleeper.Start(); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = sleeper.Process.Kill(); _ = sleeper.Wait() })
	}
	if _, _, err := takeUID(busy); err == nil {
		t.Fatal("a uid that runs a process was taken")
	}
}
