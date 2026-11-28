// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package vm

import (
	"bufio"
	"errors"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"golang.org/x/sys/unix"

	"github.com/cyfr/locus/keeper/internal/cgroup"
	"github.com/cyfr/locus/keeper/internal/proc"
	"github.com/cyfr/locus/keeper/internal/stage"
)

// standIn starts script under sh by proc.Own, a VMM's stage's stand-in,
// its input a pipe whose end it answers: the test closes it.
func standIn(t *testing.T, script string) (proc.Process, io.WriteCloser) {
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
	p, err := proc.Own("/bin/sh", []string{"sh", "-c", script}, []string{}, []uintptr{r.Fd(), null.Fd(), null.Fd()}, "/", nil)
	_ = r.Close()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = w.Close(); p.Kill(false); <-p.Done() })
	return p, w
}

// fakeMachine is a Machine whose VMM's stage is stage, already started, and
// whose vsock socket is a listener in its folder that the test answers as
// Firecracker's device would; its uid and gid are the test's own. Each of
// setup is applied before its waiter starts.
func fakeMachine(t *testing.T, stage proc.Process, setup ...func(*Machine)) (*Machine, net.Listener) {
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
	m := &Machine{dir: dir, uid: os.Getuid(), gid: os.Getgid(), stage: stage, done: make(chan struct{})}
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
	stage, _ := standIn(t, "exit 23")
	m, _ := fakeMachine(t, stage)
	<-m.done
	if got := m.End(time.Second); got != EndOwnExit {
		t.Fatalf("a VMM that exited 23 ended %q, not %q", got, EndOwnExit)
	}
}

// An end the guest's first process acknowledged, after which the VMM exits,
// is the acknowledged one.
func TestAnAcknowledgedEndIsSaidSo(t *testing.T) {
	stage, stdin := standIn(t, "read x")
	m, l := fakeMachine(t, stage)
	answerEnd(t, l, EndAck, func() { _ = stdin.Close() })
	if got := m.End(5 * time.Second); got != EndAcknowledged {
		t.Fatalf("an acknowledged end was said as %q", got)
	}
}

// A VMM that exits while its end was asked but never acknowledged is its
// own exit: a guest that died as the host asked.
func TestAnUnacknowledgedEndIsTheVMMsOwnExit(t *testing.T) {
	stage, stdin := standIn(t, "read x")
	m, l := fakeMachine(t, stage)
	answerEnd(t, l, "", func() { _ = stdin.Close() })
	if got := m.End(5 * time.Second); got != EndOwnExit {
		t.Fatalf("an unacknowledged end was said as %q", got)
	}
}

// A VMM still running past the end's bound is killed, and said so.
func TestAVMMPastItsBoundIsKilled(t *testing.T) {
	stage, _ := standIn(t, "read x")
	m, l := fakeMachine(t, stage)
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
	stage, _ := standIn(t, "exit 23")
	m, _ := fakeMachine(t, stage, func(m *Machine) {
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

// reapingStart is the keeper's start in small (package serve's startTool):
// its reaper takes every child of the test's process that exits, as the
// keeper's takes every child of the keeper's, and hands each end to the
// start that made it. started says whether it started pid, and calls are
// the argv it was asked to start, in order. Where standIn is not "", each
// start runs it under sh in place of what it was asked, with the
// descriptors it was given and their ids left the test's own.
func reapingStart(t *testing.T, standIn string) (start proc.Start, started func(pid int) bool, calls func() [][]string) {
	var mu sync.Mutex
	waiting, ever := map[int]*reapedChild{}, map[int]bool{}
	var asked [][]string
	stop, stopped := make(chan struct{}), make(chan struct{})
	go func() {
		defer close(stopped)
		tick := time.NewTicker(5 * time.Millisecond)
		defer tick.Stop()
		for {
			select {
			case <-stop:
				return
			case <-tick.C:
			}
			mu.Lock()
			for {
				var ws unix.WaitStatus
				pid, err := unix.Wait4(-1, &ws, unix.WNOHANG, nil)
				if err == unix.EINTR {
					continue
				}
				if err != nil || pid <= 0 {
					break
				}
				if c := waiting[pid]; c != nil {
					c.status = ws
					close(c.done)
					delete(waiting, pid)
				}
			}
			mu.Unlock()
		}
	}()
	t.Cleanup(func() { close(stop); <-stopped })
	start = func(argv0 string, argv, env []string, files []uintptr, dir string, sys *syscall.SysProcAttr) (proc.Process, error) {
		mu.Lock()
		defer mu.Unlock()
		asked = append(asked, append([]string{}, argv...))
		if standIn != "" {
			argv0, argv = "/bin/sh", []string{"sh", "-c", standIn}
			own := *sys
			own.Credential = nil
			sys = &own
		}
		pid, err := syscall.ForkExec(argv0, argv, &syscall.ProcAttr{Dir: dir, Env: env, Files: files, Sys: sys})
		if err != nil {
			return nil, err
		}
		c := &reapedChild{pid: pid, done: make(chan struct{}), mu: &mu}
		waiting[pid], ever[pid] = c, true
		return c, nil
	}
	started = func(pid int) bool { mu.Lock(); defer mu.Unlock(); return ever[pid] }
	calls = func() [][]string { mu.Lock(); defer mu.Unlock(); return slices.Clone(asked) }
	return start, started, calls
}

type reapedChild struct {
	pid    int
	done   chan struct{}
	status unix.WaitStatus
	mu     *sync.Mutex
}

func (c *reapedChild) Pid() int                         { return c.pid }
func (c *reapedChild) Done() <-chan struct{}            { return c.done }
func (c *reapedChild) Status() (unix.WaitStatus, error) { return c.status, nil }
func (c *reapedChild) Kill(group bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	select {
	case <-c.done:
		return
	default:
	}
	pid := c.pid
	if group {
		pid = -pid
	}
	_ = unix.Kill(pid, unix.SIGKILL)
}

// folderGroup is a machine's group in a folder laid out as cgroup2's: the
// stage's pid is written to it and read back, and no kernel bounds it.
func folderGroup(t *testing.T) *cgroup.Group {
	t.Helper()
	root := t.TempDir()
	files := map[string]string{"cgroup.controllers": "cpu memory pids\n", "memory.max": "max\n", "cgroup.procs": ""}
	for name, body := range files {
		if err := os.WriteFile(filepath.Join(root, name), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	leaf := filepath.Join(root, "service", "keeper")
	if err := os.MkdirAll(leaf, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"memory.max", "memory.swap.max", "memory.oom.group", "cpu.max", "cgroup.procs"} {
		if err := os.WriteFile(filepath.Join(leaf, name), nil, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	m, err := cgroup.Delegate(root, []byte("0::/\n"))
	if err != nil {
		t.Fatal(err)
	}
	tree, err := m.NewTree()
	if err != nil {
		t.Fatal(err)
	}
	groups, _, err := tree.Role("machines", 0, false)
	if err != nil {
		t.Fatal(err)
	}
	g, err := groups.Create(cgroup.Name(59996), 256<<20, cgroup.CPUPeriod)
	if err != nil {
		t.Fatal(err)
	}
	return g
}

// A VMM's stage is started by the start its machine is given. In the
// keeper that is the keeper's own, whose reaper takes every child of the
// keeper's that exits: a stage the machine started and waited for by itself
// there would lose its end to that reaper. Under a stand-in for it, the
// stage is one of that start's children, and the machine's end is the
// stage's own exit, as that reaper read it.
func TestAVMMsStageIsStartedAndReapedByItsKeepersStart(t *testing.T) {
	if os.Getuid() != 0 {
		t.Skip("a stage's space is cloned with capabilities root alone holds")
	}
	start, started, _ := reapingStart(t, "")
	dir := t.TempDir()
	self := filepath.Join(dir, "stage")
	// The stand-in reads its spec, says it has executed by closing its
	// status pipe, and exits 23.
	if err := os.WriteFile(self, []byte("#!/bin/sh\ncat <&3 >/dev/null\nexec 4>&-\nexit 23\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	m := &Machine{dir: dir, group: folderGroup(t), done: make(chan struct{})}
	if err := m.startStage(self, stage.Spec{UID: 59996, GID: 59996}, Config{Start: start}); err != nil {
		t.Fatal(err)
	}
	select {
	case <-m.Done():
	case <-time.After(10 * time.Second):
		t.Fatal("the stage's end did not reach its machine")
	}
	if !started(m.PID()) {
		t.Fatalf("the VMM's stage %d is no child of its machine's start", m.PID())
	}
	if ws, err := m.Status(); err != nil || !ws.Exited() || ws.ExitStatus() != 23 {
		t.Fatalf("a stage that exited 23 ended %v, %v", ws, err)
	}
}

// The retirement of a VMM's uid at its machine's end is started by the
// machine's start, the keeper's own, and its end is the one that start's
// reaper read: none of the keeper's children is waited for but by it.
func TestAVMMsRetirementIsStartedByItsMachinesStart(t *testing.T) {
	// Each keeper's stand-in runs alone, in a subtest of its own: two
	// reapers in one process take each other's children.
	t.Run("clean", func(t *testing.T) {
		start, _, calls := reapingStart(t, "cat <&3 >/dev/null")
		if err := runRetire(start, os.Getuid(), os.Getgid(), t.TempDir()); err != nil {
			t.Fatal(err)
		}
		if got := calls(); len(got) != 1 || !slices.Equal(got[0], []string{"cyfr-locus", "retire"}) {
			t.Fatalf("the machine's start was asked to start %v, not the retirement", got)
		}
	})
	t.Run("failing", func(t *testing.T) {
		start, _, _ := reapingStart(t, "cat <&3 >/dev/null; exit 4")
		if err := runRetire(start, os.Getuid(), os.Getgid(), t.TempDir()); err == nil || !strings.Contains(err.Error(), "exit status 4") {
			t.Fatalf("a retirement that exited 4 answered %v", err)
		}
	})
}

// A uid or gid outside 0 to 2^31-1 is refused before anything is started
// as it, where it would be converted to the kernel's form.
func TestARetirementOfNoUIDIsRefused(t *testing.T) {
	started := false
	start := func(string, []string, []string, []uintptr, string, *syscall.SysProcAttr) (proc.Process, error) {
		started = true
		return nil, errors.New("not started")
	}
	for _, ids := range [][2]int{{-1, 0}, {1 << 31, 0}, {0, -1}, {0, 1 << 31}} {
		if err := runRetire(start, ids[0], ids[1], t.TempDir()); err == nil || !strings.Contains(err.Error(), "is not a uid and gid") || started {
			t.Fatalf("a retirement as %d:%d answered %v, started %t", ids[0], ids[1], err, started)
		}
	}
}
