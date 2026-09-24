// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package serve

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"golang.org/x/sys/unix"

	"github.com/cyfr/keeper/internal/cgroup"
	"github.com/cyfr/keeper/internal/frame"
	"github.com/cyfr/keeper/internal/logx"
	"github.com/cyfr/keeper/internal/pool"
	"github.com/cyfr/keeper/internal/protocol"
)

// boundedKeeper is a keeper that enforces memory bounds. Beyond root it
// needs what the shipped services give the spawner: a cgroup namespace whose
// root is mounted writable (`docker run --security-opt writable-cgroups=true`).
func boundedKeeper(t *testing.T) *keeper {
	t.Helper()
	k := newKeeper(t)
	self, err := os.ReadFile(cgroup.SelfPath)
	if err != nil {
		t.Fatal(err)
	}
	memory, err := cgroup.Delegate(cgroup.Root, self)
	if err != nil {
		t.Skipf("no memory bound can be enforced here: %v", err)
	}
	k.s.memory = memory
	return k
}

// replies reads the channel until every one of the spawns has been reported
// released, and answers each spawn's `exited`.
func (k *keeper) replies(t *testing.T, spawnIDs ...string) map[string]map[string]any {
	t.Helper()
	exited := map[string]map[string]any{}
	released := map[string]bool{}
	for len(released) < len(spawnIDs) {
		m := k.reply(t)
		id, _ := m["spawn_id"].(string)
		switch m["type"] {
		case protocol.TypeExited:
			exited[id] = m
		case protocol.TypeReleased:
			released[id] = true
		default:
			t.Fatalf("unexpected reply %v", m)
		}
	}
	return exited
}

func groupExists(uid int) bool {
	_, err := os.Stat(filepath.Join(cgroup.Root, cgroup.Name(uid)))
	return err == nil
}

func TestASpawnAskingForABoundIsRefusedWhereNoneCanBeEnforced(t *testing.T) {
	fds, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_STREAM|unix.SOCK_CLOEXEC, 0)
	if err != nil {
		t.Fatal(err)
	}
	if err := unix.SetNonblock(fds[0], true); err != nil {
		t.Fatal(err)
	}
	theirs := os.NewFile(uintptr(fds[1]), "client-channel")
	defer theirs.Close()
	spec := pool.Spec{Name: "runner", First: testPoolFirst, Last: testPoolLast}
	s := &server{
		log:     logx.NewWriter(os.Stderr, "cyfr-keeper", false),
		pools:   map[string]*pool.Pool{spec.Name: pool.New(spec)},
		spawns:  map[string]*spawn{},
		channel: os.NewFile(uintptr(fds[0]), "channel"),
	}
	defer s.channel.Close()

	s.handleSpawn(spawnRequest(t, "/run/a.sock", "41", "true", map[string]string{}, false, 64<<20))

	k := &keeper{s: s, channel: protocol.NewLineReader(theirs)}
	refused := k.reply(t)
	if refused["type"] != protocol.TypeError || refused["id"] != "41" || refused["code"] != protocol.CodeMemoryUnavailable {
		t.Fatalf("a bound that cannot be enforced was answered %v", refused)
	}
	if st := s.pools["runner"].Stats(); st.Free != st.Size || len(s.spawns) != 0 {
		t.Fatalf("the refused spawn holds a uid: %+v", st)
	}
}

func TestABoundedSpawnRunsInAGroupOfItsOwnItCannotChange(t *testing.T) {
	k := boundedKeeper(t)
	script := `cat /proc/self/cgroup
own="/sys/fs/cgroup$(cut -d: -f3 /proc/self/cgroup)"
echo "max=$(cat "$own/memory.max") swap=$(cat "$own/memory.swap.max") group=$(cat "$own/memory.oom.group")"
echo max 2>/dev/null > "$own/memory.max" && echo raised
echo 0 2>/dev/null > "$own/memory.oom.group" && echo ungrouped
echo $$ 2>/dev/null > /sys/fs/cgroup/keeper/cgroup.procs && echo moved
mkdir "$own/inner" 2>/dev/null && echo nested
cat /proc/self/cgroup`
	spawnID, uid, rc := k.spawnBounded(t, "42", script, map[string]string{}, false, 64<<20)
	rc.readUntil(t, func() bool { return false })
	group := "0::/" + cgroup.Name(uid) + "\n"
	want := group + "max=67108864 swap=0 group=1\n" + group
	if got := string(rc.got[frame.StreamStdout]); got != want {
		t.Fatalf("the spawn saw\n%s\nwant\n%s", got, want)
	}
	exited := k.replies(t, spawnID)[spawnID]
	if exited["code"] != float64(0) || exited["memory_exceeded"] != false {
		t.Fatalf("exit: %v", exited)
	}
	assertRetired(t, k, uid)
	if groupExists(uid) {
		t.Fatalf("the group of uid %d outlived its spawn", uid)
	}
}

func TestASpawnPastItsBoundIsKilledWholeAndReportedSoWhileASiblingCompletes(t *testing.T) {
	k := boundedKeeper(t)
	// The sibling holds 8 MiB under a bound of 64; the hostile spawn forks
	// eight holders of 16 MiB under a bound of 64, none of them large, and
	// a daemon in a session of its own that ignores SIGTERM.
	sibling := fmt.Sprintf("exec %s hold 8 4", k.s.self)
	hostile := fmt.Sprintf(`setsid sh -c "trap '' TERM; exec sleep 1000" </dev/null >/dev/null 2>&1 &
for i in 1 2 3 4 5 6 7 8; do %s hold 16 60 & done
wait`, k.s.self)

	siblingID, siblingUID, siblingConn := k.spawnBounded(t, "43", sibling, map[string]string{}, false, 64<<20)
	hostileID, hostileUID, hostileConn := k.spawnBounded(t, "44", hostile, map[string]string{}, false, 64<<20)
	exited := k.replies(t, siblingID, hostileID)

	if e := exited[hostileID]; e["signal"] != "SIGKILL" || e["code"] != nil || e["memory_exceeded"] != true {
		t.Fatalf("the spawn past its bound exited %v", e)
	}
	if e := exited[siblingID]; e["code"] != float64(0) || e["memory_exceeded"] != false {
		t.Fatalf("the sibling exited %v", e)
	}
	siblingConn.readUntil(t, func() bool { return false })
	if got := string(siblingConn.got[frame.StreamStdout]); got != "held\n" {
		t.Fatalf("the sibling wrote %q", got)
	}
	hostileConn.readUntil(t, func() bool { return false })
	if held := strings.Count(string(hostileConn.got[frame.StreamStdout]), "held\n"); held >= 8 {
		t.Fatalf("all %d holders fit under a bound half their size", held)
	}
	for _, uid := range []int{hostileUID, siblingUID} {
		if groupExists(uid) {
			t.Fatalf("the group of uid %d outlived its spawn", uid)
		}
	}
	assertRetired(t, k, hostileUID)
}

func TestAnExitForAnotherReasonIsNotAMemoryEnd(t *testing.T) {
	k := boundedKeeper(t)
	spawnID, uid, _ := k.spawnBounded(t, "45", "kill -KILL $$", map[string]string{}, false, 64<<20)
	if e := k.replies(t, spawnID)[spawnID]; e["signal"] != "SIGKILL" || e["memory_exceeded"] != false {
		t.Fatalf("a spawn that killed itself exited %v", e)
	}
	assertRetired(t, k, uid)

	// A uid's next spawn gets a fresh group: nothing the counters of the
	// spawn killed at its bound held reaches a later report.
	spawnID, killed, _ := k.spawnBounded(t, "46", fmt.Sprintf("exec %s hold 128 60", k.s.self), map[string]string{}, false, 32<<20)
	if e := k.replies(t, spawnID)[spawnID]; e["signal"] != "SIGKILL" || e["memory_exceeded"] != true {
		t.Fatalf("a spawn past its bound exited %v", e)
	}
	assertRetired(t, k, killed)
	for next := 47; ; next++ {
		spawnID, uid, _ := k.spawnBounded(t, fmt.Sprint(next), "true", map[string]string{}, false, 32<<20)
		if e := k.replies(t, spawnID)[spawnID]; e["code"] != float64(0) || e["memory_exceeded"] != false {
			t.Fatalf("a spawn after it, under uid %d, exited %v", uid, e)
		}
		assertRetired(t, k, uid)
		if uid == killed {
			break
		}
		if next > 47+testPoolLast-testPoolFirst {
			t.Fatalf("uid %d was never lent again", killed)
		}
	}
}
