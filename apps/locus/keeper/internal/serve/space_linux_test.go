// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package serve

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"
	"unsafe"

	"golang.org/x/sys/unix"

	"github.com/cyfr/locus/keeper/internal/frame"
	"github.com/cyfr/locus/keeper/internal/protocol"
	"github.com/cyfr/locus/keeper/internal/stage"
)

// tryMounts is the space tests' command: it tries each call that makes a
// mount or a namespace and prints `<call>: <errno>` for each.
func tryMounts() int {
	tries := []struct {
		name string
		call func() error
	}{
		{"mount", func() error { return unix.Mount("none", "/tmp", "tmpfs", 0, "") }},
		{"umount2", func() error { return unix.Unmount("/proc", unix.MNT_DETACH) }},
		{"pivot_root", func() error { return unix.PivotRoot("/tmp", "/tmp") }},
		{"open_tree", func() error {
			fd, err := unix.OpenTree(unix.AT_FDCWD, "/tmp", unix.OPEN_TREE_CLONE)
			if err == nil {
				unix.Close(fd)
			}
			return err
		}},
		{"fsopen", func() error {
			fd, err := unix.Fsopen("tmpfs", 0)
			if err == nil {
				unix.Close(fd)
			}
			return err
		}},
		{"mount_setattr", func() error {
			return unix.MountSetattr(unix.AT_FDCWD, "/tmp", 0, &unix.MountAttr{Attr_clr: unix.MOUNT_ATTR_RDONLY})
		}},
		{"unshare", func() error { return unix.Unshare(unix.CLONE_NEWNS) }},
	}
	for _, try := range tries {
		err := try.call()
		var errno unix.Errno
		switch {
		case err == nil:
			fmt.Printf("%s: allowed\n", try.name)
		case errors.As(err, &errno):
			fmt.Printf("%s: %s\n", try.name, unix.ErrnoName(errno))
		default:
			fmt.Printf("%s: %v\n", try.name, err)
		}
	}
	return 0
}

// regexpFind answers the first group of pattern's first match in s.
func regexpFind(pattern, s string) string {
	m := regexp.MustCompile(pattern).FindStringSubmatch(s)
	if m == nil {
		return ""
	}
	return m[1]
}

// queue is the space tests' POSIX message queue command: `queue make NAME`
// makes the queue and prints `made` once it holds it, then holds it until
// it is ended;
// `queue open NAME` opens it and prints `open` or the errno's name.
func queue(args []string) int {
	if len(args) != 2 {
		return 2
	}
	// The call takes the name without the slash the C library strips.
	name, err := unix.BytePtrFromString(strings.TrimPrefix(args[1], "/"))
	if err != nil {
		return 2
	}
	flags := unix.O_RDONLY
	if args[0] == "make" {
		flags = unix.O_CREAT | unix.O_EXCL | unix.O_RDWR
	}
	fd, _, errno := unix.Syscall6(unix.SYS_MQ_OPEN, uintptr(unsafe.Pointer(name)), uintptr(flags), 0o600, 0, 0, 0)
	switch {
	case errno != 0:
		fmt.Println(unix.ErrnoName(errno))
	case args[0] == "make":
		fmt.Println("made")
		time.Sleep(time.Hour) // sleep-ok: the queue is held until the test ends the session
		_ = unix.Close(int(fd))
	default:
		fmt.Println("open")
		_ = unix.Close(int(fd))
	}
	return 0
}

// pidsOf answers the pids, as this test's namespace numbers them, of the
// processes of uid named comm.
func pidsOf(t *testing.T, uid int, comm string) []int {
	t.Helper()
	entries, err := os.ReadDir("/proc")
	if err != nil {
		t.Fatal(err)
	}
	var pids []int
	for _, e := range entries {
		pid, err := strconv.Atoi(e.Name())
		if err != nil {
			continue
		}
		status, err := os.ReadFile(filepath.Join("/proc", e.Name(), "status"))
		if err != nil {
			continue
		}
		name, err := os.ReadFile(filepath.Join("/proc", e.Name(), "comm"))
		if err != nil || strings.TrimSpace(string(name)) != comm {
			continue
		}
		if strings.Contains(string(status), "\nUid:\t"+strconv.Itoa(uid)+"\t") {
			pids = append(pids, pid)
		}
	}
	return pids
}

// Two sessions of one folder, a kept home's spawns under its one uid, each
// see and signal only their own: each lists its own processes alone, under
// the space's init as pid 1, cannot signal the other's, has a /tmp of its
// own, sees its own home alone under the kept homes' root, no terminal of
// another, no group but its own, whose cap it reads at the root of its
// cgroup tree, and can mount nothing.
func TestTwoSessionsOfOneFolderSeeAndSignalOnlyTheirOwn(t *testing.T) {
	k := keptKeeper(t)
	uid := testKeptFirst
	path := filepath.Join(k.s.cfg.Kept.Root, "vlt_home-two")
	other := filepath.Join(k.s.cfg.Kept.Root, "vlt_home-other")
	for i, h := range []struct {
		path string
		uid  int
	}{{path, uid}, {other, uid + 1}} {
		if made := k.homeRequest(t, protocol.TypeHomeMake, "m"+strconv.Itoa(i), h.path, h.uid); made["type"] != protocol.TypeHomeMade {
			t.Fatalf("home_make %s: %v", h.path, made)
		}
	}
	a, rcA := k.spawnKept(t, "a", `echo a > /tmp/mine; echo ready; exec sleep 600`, path, uid)
	rcA.readUntil(t, func() bool { return strings.Contains(string(rcA.got[frame.StreamStdout]), "ready\n") })
	var sleeps []int
	for deadline := time.Now().Add(10 * time.Second); len(sleeps) == 0 && time.Now().Before(deadline); time.Sleep(20 * time.Millisecond) {
		sleeps = pidsOf(t, uid, "sleep")
	}
	if len(sleeps) != 1 {
		t.Fatalf("the first session's sleep, as the keeper numbers it: %v", sleeps)
	}
	script := fmt.Sprintf(`echo "comms:$(for p in /proc/[0-9]*; do cat $p/comm; done | sort -u | tr '\n' ' ')"
echo "init:$(cat /proc/1/comm)"
kill -0 %d 2>/dev/null && echo signalled || echo unsignalled
echo "mine:$(cat /tmp/mine 2>/dev/null || echo none)"
echo "homes:$(ls -A %s | tr '\n' ' ')"
echo "pts:$(ls -A /dev/pts | tr '\n' ' ')"
echo "groups:$(find /sys/fs/cgroup -mindepth 1 -type d | wc -l)"
echo "cap:$(cat /sys/fs/cgroup/memory.max)"
echo "tmpdir:$TMPDIR"
%s mounts
echo done`, sleeps[0], k.s.cfg.Kept.Root, k.helper)
	b, rcB := k.spawnKept(t, "b", script, path, uid)
	rcB.readUntil(t, func() bool { return false })
	stdout := string(rcB.got[frame.StreamStdout])
	for _, want := range []string{
		"init:cyfr-locus\n", "unsignalled\n", "mine:none\n", "homes:" + filepath.Base(path) + " \n", "pts:ptmx \n",
		"groups:0\n", "cap:67108864\n", "tmpdir:/tmp\n",
		"mount: EPERM\n", "umount2: EPERM\n", "pivot_root: EPERM\n", "open_tree: EPERM\n", "fsopen: EPERM\n",
		"mount_setattr: EPERM\n", "unshare: EPERM\n", "done\n",
	} {
		if !strings.Contains(stdout, want) {
			t.Errorf("the second session lacks %q:\n%s", want, stdout)
		}
	}
	if comms := regexpFind(`comms:([^\n]*)`, stdout); strings.Contains(comms, "sleep") || !strings.Contains(comms, "cyfr-locus") {
		t.Errorf("the second session lists %q", comms)
	}
	k.releasedPair(t, b)
	if got := pidsOf(t, uid, "sleep"); len(got) != 1 || got[0] != sleeps[0] {
		t.Fatalf("the first session's sleep after the second's end: %v", got)
	}
	k.release(t, a)
	k.releasedPair(t, a)
}

// The space's init ends every process of the space with the command. A
// daemon one session of a kept home left, out of the command's session,
// is gone once that session has ended, though another session of the home
// lives on under the same uid, which the uid's retirement waits for. The
// exit told carries the command's own code, and a command ended by a
// signal is told so, by that signal.
func TestASpacesProcessesEndWithItsCommand(t *testing.T) {
	k := keptKeeper(t)
	uid := testKeptFirst
	path := filepath.Join(k.s.cfg.Kept.Root, "vlt_home-end")
	if made := k.homeRequest(t, protocol.TypeHomeMake, "m", path, uid); made["type"] != protocol.TypeHomeMade {
		t.Fatalf("home_make: %v", made)
	}
	sibling, rc := k.spawnKept(t, "sibling", `echo ready; exec sleep 600`, path, uid)
	rc.readUntil(t, func() bool { return strings.Contains(string(rc.got[frame.StreamStdout]), "ready\n") })
	ended, rc := k.spawnKept(t, "daemon", `setsid nohup sleep 601 </dev/null >/dev/null 2>&1 & echo started; exit 3`, path, uid)
	rc.readUntil(t, func() bool { return false })
	if !strings.Contains(string(rc.got[frame.StreamStdout]), "started\n") {
		t.Fatalf("stdout %q", rc.got[frame.StreamStdout])
	}
	told := map[string]map[string]any{}
	for len(told) < 2 {
		m := k.reply(t)
		told[m["type"].(string)] = m
	}
	if e := told[protocol.TypeExited]; e["spawn_id"] != ended || e["code"] != float64(3) {
		t.Fatalf("exit: %v", told)
	}
	if left := pidsRunning(t, uid, "sleep 601"); len(left) != 0 {
		t.Fatalf("the daemon outlived its session: %v", left)
	}
	if lives := pidsRunning(t, uid, "sleep 600"); len(lives) != 1 {
		t.Fatalf("the other session's command: %v", lives)
	}

	signalled, rc := k.spawnKept(t, "segv", `kill -SEGV $$`, path, uid)
	rc.readUntil(t, func() bool { return false })
	told = map[string]map[string]any{}
	for len(told) < 2 {
		m := k.reply(t)
		told[m["type"].(string)] = m
	}
	if e := told[protocol.TypeExited]; e["spawn_id"] != signalled || e["signal"] != "SIGSEGV" || e["code"] != nil {
		t.Fatalf("exit: %v", told)
	}
	k.release(t, sibling)
	k.releasedPair(t, sibling)
}

// pidsRunning answers the pids, as this test's namespace numbers them, of
// the processes of uid whose command line is cmdline.
func pidsRunning(t *testing.T, uid int, cmdline string) []int {
	t.Helper()
	var pids []int
	for _, pid := range pidsOf(t, uid, strings.Fields(cmdline)[0]) {
		raw, err := os.ReadFile(filepath.Join("/proc", strconv.Itoa(pid), "cmdline"))
		if err == nil && strings.Join(strings.Split(strings.TrimRight(string(raw), "\x00"), "\x00"), " ") == cmdline {
			pids = append(pids, pid)
		}
	}
	return pids
}

// A signal the keeper is asked to send reaches the command inside its
// space, past the stage's waiter and the space's init, which both live on
// until the command ends.
func TestASignalReachesTheCommandInsideItsSpace(t *testing.T) {
	k := newKeeper(t).withMemory(t)
	id, uid, rc := k.spawn(t, "t", `trap 'echo got:TERM; exit 0' TERM; echo ready; while :; do sleep 0.05; done`, map[string]string{}, false)
	rc.readUntil(t, func() bool { return strings.Contains(string(rc.got[frame.StreamStdout]), "ready\n") })
	k.s.handle(parsed(t, `{"v":`+strconv.Itoa(protocol.Version)+`,"type":"signal","spawn_id":"`+id+`","sig":"SIGTERM"}`))
	rc.readUntil(t, func() bool { return false })
	if got := string(rc.got[frame.StreamStdout]); !strings.Contains(got, "got:TERM\n") {
		t.Fatalf("stdout %q", got)
	}
	if exited := k.reply(t); exited["spawn_id"] != id || exited["code"] != float64(0) {
		t.Fatalf("exit: %v", exited)
	}
	k.reply(t)
	assertRetired(t, k, uid)
}

// A host on which a space's first process cannot build its files refuses
// the probe, naming the step.
func TestTheProbeRefusesAHostThatCannotBuildASpacesFiles(t *testing.T) {
	k := newKeeper(t)
	if err := os.Remove(stage.Root); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.MkdirAll(stage.Root, 0o755) })
	spec := k.s.cfg.Pools[0]
	err := probeSpace(k.s.self, spec, k.s.accounts[spec.First])
	if err == nil || !strings.Contains(err.Error(), "the space's files") || !strings.Contains(err.Error(), stage.Root) {
		t.Fatalf("the probe without %s: %v", stage.Root, err)
	}
}

// No thread of any process a spawn runs under its uid holds a capability
// in any set, in its space or outside it: the stage's waiter, the space's
// init and the command alike.
func TestNoThreadOfASpaceHoldsACapability(t *testing.T) {
	k := newKeeper(t).withMemory(t)
	id, uid, rc := k.spawn(t, "c", `echo ready; exec sleep 600`, map[string]string{}, false)
	rc.readUntil(t, func() bool { return strings.Contains(string(rc.got[frame.StreamStdout]), "ready\n") })
	k.s.mu.Lock()
	leader := k.s.spawns[id].leader.pid
	k.s.mu.Unlock()
	var pids []int
	for deadline := time.Now().Add(10 * time.Second); time.Now().Before(deadline); time.Sleep(20 * time.Millisecond) {
		if pids = append(pidsOf(t, uid, "cyfr-locus"), pidsOf(t, uid, "sleep")...); len(pids) >= 3 {
			break
		}
	}
	if len(pids) < 3 || !containsInt(pids, leader) {
		t.Fatalf("the waiter %d, the init and the command of uid %d: %v", leader, uid, pids)
	}
	for _, pid := range pids {
		tasks, err := os.ReadDir(filepath.Join("/proc", strconv.Itoa(pid), "task"))
		if err != nil {
			t.Fatal(err)
		}
		for _, task := range tasks {
			status, err := os.ReadFile(filepath.Join("/proc", strconv.Itoa(pid), "task", task.Name(), "status"))
			if err != nil {
				t.Fatal(err)
			}
			for _, set := range []string{"CapInh", "CapPrm", "CapEff", "CapBnd", "CapAmb"} {
				if !strings.Contains(string(status), "\n"+set+":\t0000000000000000\n") {
					t.Errorf("thread %s of process %d holds %s:\n%s", task.Name(), pid, set, status)
				}
			}
		}
	}
	k.release(t, id)
	k.replies(t, id)
	assertRetired(t, k, uid)
}

func containsInt(list []int, v int) bool {
	for _, x := range list {
		if x == v {
			return true
		}
	}
	return false
}

// A kept session's close sends SIGTERM to its command alone, which the
// space passes down unchanged: a child the command ends itself, as a driver
// closes its browser, is not sent it, and what the command says before it
// ends is carried.
func TestAKeptClosesSignalReachesTheCommandAlone(t *testing.T) {
	k := keptKeeper(t)
	uid := testKeptFirst
	path := filepath.Join(k.s.cfg.Kept.Root, "vlt_home-close")
	if made := k.homeRequest(t, protocol.TypeHomeMake, "m", path, uid); made["type"] != protocol.TypeHomeMade {
		t.Fatalf("home_make: %v", made)
	}
	script := `sh -c 'trap "echo child:signalled; exit 0" TERM; while :; do sleep 0.05; done' & child=$!
trap 'sleep 0.2; kill -KILL $child; echo bye; exit 0' TERM
echo ready
wait`
	id, rc := k.spawnKept(t, "c", script, path, uid)
	rc.readUntil(t, func() bool { return strings.Contains(string(rc.got[frame.StreamStdout]), "ready\n") })
	grace := int64(5000)
	k.s.handleRelease(&protocol.Request{V: protocol.Version, Type: protocol.TypeRelease, SpawnID: id, GraceMs: &grace})
	rc.readUntil(t, func() bool { return false })
	if got := string(rc.got[frame.StreamStdout]); got != "ready\nbye\n" {
		t.Fatalf("the closed session said %q", got)
	}
	k.releasedPair(t, id)
}

// A kept close ends a session in order, as a program's own wrapper meets
// it: the command, a shell running the program as its child, ends at the
// SIGTERM, and the program it leaves is sent SIGTERM in its turn and says
// what it says before it ends, within the close's grace.
func TestAKeptCloseEndsWhatTheCommandLeftInItsTurn(t *testing.T) {
	k := keptKeeper(t)
	uid := testKeptFirst
	path := filepath.Join(k.s.cfg.Kept.Root, "vlt_home-order")
	if made := k.homeRequest(t, protocol.TypeHomeMake, "m", path, uid); made["type"] != protocol.TypeHomeMade {
		t.Fatalf("home_make: %v", made)
	}
	script := `sh -c 'trap "sleep 0.2; echo bye; exit 0" TERM; echo ready; while :; do sleep 0.05; done'; echo after`
	id, rc := k.spawnKept(t, "o", script, path, uid)
	rc.readUntil(t, func() bool { return strings.Contains(string(rc.got[frame.StreamStdout]), "ready\n") })
	grace := int64(5000)
	k.s.handleRelease(&protocol.Request{V: protocol.Version, Type: protocol.TypeRelease, SpawnID: id, GraceMs: &grace})
	rc.readUntil(t, func() bool { return false })
	if got := string(rc.got[frame.StreamStdout]); got != "ready\nbye\n" {
		t.Fatalf("the closed session said %q", got)
	}
	k.releasedPair(t, id)
}

// A space's POSIX message queue is its own: a session makes one and opens
// it again, another session of the same folder and uid finds none of that
// name, and once the first has ended no later session finds it.
func TestASpacesMessageQueueIsItsOwn(t *testing.T) {
	k := keptKeeper(t)
	uid := testKeptFirst
	path := filepath.Join(k.s.cfg.Kept.Root, "vlt_home-queue")
	if made := k.homeRequest(t, protocol.TypeHomeMake, "m", path, uid); made["type"] != protocol.TypeHomeMade {
		t.Fatalf("home_make: %v", made)
	}
	maker, rc := k.spawnKept(t, "q", fmt.Sprintf(`%s queue make /l7-queue & sleep 0.3; %s queue open /l7-queue; wait`,
		k.helper, k.helper), path, uid)
	rc.readUntil(t, func() bool {
		return strings.Contains(string(rc.got[frame.StreamStdout]), "open\n") || rc.ended[frame.StreamStdout]
	})
	if got := string(rc.got[frame.StreamStdout]); got != "made\nopen\n" {
		t.Fatalf("the session could not make and open a queue of its own: %q", got)
	}
	look := func(id string) string {
		other, orc := k.spawnKept(t, id, k.helper+" queue open /l7-queue", path, uid)
		orc.readUntil(t, func() bool { return false })
		k.releasedPair(t, other)
		return string(orc.got[frame.StreamStdout])
	}
	if got := look("b"); got != "ENOENT\n" {
		t.Fatalf("another session of the folder opened the queue: %q", got)
	}
	k.release(t, maker)
	k.releasedPair(t, maker)
	if got := look("c"); got != "ENOENT\n" {
		t.Fatalf("a later session opened the ended session's queue: %q", got)
	}
}
