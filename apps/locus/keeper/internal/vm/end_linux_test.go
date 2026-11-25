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
	"testing"
	"time"
)

// fakeMachine is a Machine whose VMM is cmd, already started, and whose
// vsock socket is a listener in its folder that the test answers as
// Firecracker's device would; its uid and gid are the test's own.
func fakeMachine(t *testing.T, cmd *exec.Cmd) (*Machine, net.Listener) {
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
	go func() {
		_ = cmd.Wait()
		close(m.done)
	}()
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
