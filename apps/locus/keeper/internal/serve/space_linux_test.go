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
echo done`, sleeps[0], k.s.cfg.Kept.Root, k.s.self)
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

// The space's init ends every process of the space with the command: a
// daemon that left the command's session is gone when the command's exit is
// told, which carries the command's own code, and a command ended by a
// signal is told so, by that signal.
func TestASpacesProcessesEndWithItsCommand(t *testing.T) {
	k := newKeeper(t).withMemory(t)
	id, uid, rc := k.spawn(t, "d", `setsid nohup sleep 600 </dev/null >/dev/null 2>&1 & echo started; exit 3`, map[string]string{}, false)
	rc.readUntil(t, func() bool { return false })
	if !strings.Contains(string(rc.got[frame.StreamStdout]), "started\n") {
		t.Fatalf("stdout %q", rc.got[frame.StreamStdout])
	}
	if exited := k.reply(t); exited["spawn_id"] != id || exited["code"] != float64(3) {
		t.Fatalf("exit: %v", exited)
	}
	if left := pidsOf(t, uid, "sleep"); len(left) != 0 {
		t.Fatalf("the daemon outlived its space's command: %v", left)
	}
	k.reply(t)
	assertRetired(t, k, uid)

	id, uid, rc = k.spawn(t, "s", `kill -SEGV $$`, map[string]string{}, false)
	rc.readUntil(t, func() bool { return false })
	if exited := k.reply(t); exited["spawn_id"] != id || exited["signal"] != "SIGSEGV" || exited["code"] != nil {
		t.Fatalf("exit: %v", exited)
	}
	k.reply(t)
	assertRetired(t, k, uid)
}

// A signal the keeper is asked to send reaches the command's process group
// inside its space, past the stage and the space's init, which both live on
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
