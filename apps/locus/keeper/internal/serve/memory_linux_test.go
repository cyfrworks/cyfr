// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package serve

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"golang.org/x/sys/unix"

	"github.com/cyfr/locus/keeper/internal/cgroup"
	"github.com/cyfr/locus/keeper/internal/frame"
	"github.com/cyfr/locus/keeper/internal/logx"
	"github.com/cyfr/locus/keeper/internal/pool"
	"github.com/cyfr/locus/keeper/internal/protocol"
)

// boundedKeeper is a keeper that enforces memory bounds. Beyond root it
// needs what the shipped services give the keeper: a cgroup namespace whose
// root is mounted writable (`docker run --security-opt writable-cgroups=true`).
func boundedKeeper(t *testing.T) *keeper {
	t.Helper()
	return newKeeper(t).withMemory(t)
}

func (k *keeper) withMemory(t *testing.T) *keeper {
	t.Helper()
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
		log:     logx.NewWriter(os.Stderr, "cyfr-locus", false),
		pools:   map[string]*pool.Pool{spec.Name: pool.New(spec)},
		spawns:  map[string]*spawn{},
		places:  map[string]*place{"41": {whose: protocol.Whose{Kind: protocol.KindRun}}},
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
echo "max=$(cat "$own/memory.max") swap=$(cat "$own/memory.swap.max") group=$(cat "$own/memory.oom.group") cpu=$(cat "$own/cpu.max")"
echo max 2>/dev/null > "$own/memory.max" && echo raised
echo max 2>/dev/null > "$own/cpu.max" && echo unbounded
echo 0 2>/dev/null > "$own/memory.oom.group" && echo ungrouped
echo 0 2>/dev/null > "$own/../memory.oom.group" && echo unmarked
echo $$ 2>/dev/null > "$own/../cgroup.procs" && echo escaped
echo $$ 2>/dev/null > /sys/fs/cgroup/keeper/cgroup.procs && echo moved
mkdir "$own/inner" 2>/dev/null && echo nested
cat /proc/self/cgroup`
	spawnID, uid, rc := k.spawnBounded(t, "42", script, map[string]string{}, false, 64<<20)
	rc.readUntil(t, func() bool { return false })
	group := "0::/" + cgroup.Name(uid) + "/bound\n"
	want := group + fmt.Sprintf("max=67108864 swap=0 group=1 cpu=%d %d\n", protocol.CPUPeriod, protocol.CPUPeriod) + group
	if got := string(rc.got[frame.StreamStdout]); got != want {
		t.Fatalf("the spawn saw\n%s\nwant\n%s", got, want)
	}
	exited := k.replies(t, spawnID)[spawnID]
	if exited["code"] != float64(0) || exited["memory"] != nil {
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

	if e := exited[hostileID]; e["signal"] != "SIGKILL" || e["code"] != nil || e["memory"] != protocol.MemoryCap {
		t.Fatalf("the spawn past its bound exited %v", e)
	}
	if e := exited[siblingID]; e["code"] != float64(0) || e["memory"] != nil {
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
	if e := k.replies(t, spawnID)[spawnID]; e["signal"] != "SIGKILL" || e["memory"] != nil {
		t.Fatalf("a spawn that killed itself exited %v", e)
	}
	assertRetired(t, k, uid)

	// A uid's next spawn gets a fresh group: nothing the counters of the
	// spawn killed at its bound held reaches a later report.
	spawnID, killed, _ := k.spawnBounded(t, "46", fmt.Sprintf("exec %s hold 128 60", k.s.self), map[string]string{}, false, 32<<20)
	if e := k.replies(t, spawnID)[spawnID]; e["signal"] != "SIGKILL" || e["memory"] != protocol.MemoryCap {
		t.Fatalf("a spawn past its bound exited %v", e)
	}
	assertRetired(t, k, killed)
	for next := 47; ; next++ {
		spawnID, uid, _ := k.spawnBounded(t, fmt.Sprint(next), "true", map[string]string{}, false, 32<<20)
		if e := k.replies(t, spawnID)[spawnID]; e["code"] != float64(0) || e["memory"] != nil {
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

func (k *keeper) measure(t *testing.T, place string) map[string]any {
	t.Helper()
	id := "measure-" + place
	k.s.handle(parsed(t, `{"v":3,"type":"measure","id":"`+id+`","place":"`+place+`"}`))
	m := k.reply(t)
	if _, named := m["spawn_id"]; named || m["id"] != id {
		t.Fatalf("measuring %s answered %v", place, m)
	}
	return m
}

// measuredAtLeast reads every spawn's group, as the reader does each second,
// and measures the place until it answers at least least bytes: the kernel
// folds memory.stat's counts in batches.
func (k *keeper) measuredAtLeast(t *testing.T, place string, least float64) map[string]any {
	t.Helper()
	for deadline := time.Now().Add(10 * time.Second); ; time.Sleep(50 * time.Millisecond) {
		k.s.read()()
		m := k.measure(t, place)
		if bytes, ok := m["bytes"].(float64); ok && m["type"] == protocol.TypeMeasured && bytes >= least {
			return m
		}
		if time.Now().After(deadline) {
			t.Fatalf("measuring %s answered %v, never %.0f bytes", place, m, least)
		}
	}
}

// A place the keeper does not hold, and one whose spawn's group cannot be
// read, are refused a reading under the measure's own id, and neither is a
// zero. It needs no root.
func TestAPlaceWithoutAReadingIsUnmeasured(t *testing.T) {
	k, _ := placesKeeper(t)
	if placed := k.place(t, "unread", protocol.KindRun); placed["type"] != protocol.TypePlaced {
		t.Fatalf("place: %v", placed)
	}
	k.spawnedIn(t, "unread", &spawn{id: strings.Repeat("a", 32), group: &cgroup.Group{}})
	k.s.read()()
	for _, id := range []string{"unread", "absent"} {
		m := k.measure(t, id)
		if _, zero := m["bytes"]; zero || m["type"] != protocol.TypeError || m["code"] != protocol.CodeUnmeasured {
			t.Fatalf("%s without a reading answered %v", id, m)
		}
	}
}

// Two spawns of one kept home share its uid and are measured apart, each
// with the tmpfs pages it wrote itself, which no process of it maps.
func TestTwoSpawnsOfOneUIDAreMeasuredApartWithTheirTmpfs(t *testing.T) {
	var fs unix.Statfs_t
	k := keptKeeper(t)
	if err := unix.Statfs("/dev/shm", &fs); err != nil || int64(fs.Type) != unix.TMPFS_MAGIC {
		t.Fatalf("/dev/shm is no tmpfs to write to: %v", err)
	}
	const mib = 1 << 20
	uid := testKeptFirst
	path := filepath.Join(k.s.cfg.Kept.Root, "vlt_measured")
	if made := k.homeRequest(t, protocol.TypeHomeMake, "m1", path, uid); made["type"] != protocol.TypeHomeMade {
		t.Fatalf("home_make: %v", made)
	}
	file := fmt.Sprintf("/dev/shm/cyfr-measured-%d", os.Getpid())
	t.Cleanup(func() { _ = os.Remove(file) })

	// Each spawn's place is its request's id.
	idle, idleConn := k.spawnKept(t, "48", "echo ready; exec sleep 60", path, uid)
	writer, writerConn := k.spawnKept(t, "49", "head -c 25165824 /dev/zero > "+file+" && echo ready; exec sleep 60", path, uid)
	for _, rc := range []*relayConn{idleConn, writerConn} {
		rc.readUntil(t, func() bool { return strings.Contains(string(rc.got[frame.StreamStdout]), "ready") })
	}

	used := map[string]float64{}
	for place, least := range map[string]float64{"48": 1, "49": 24 * mib} {
		used[place] = k.measuredAtLeast(t, place, least)["bytes"].(float64)
	}
	if used["48"] >= 16*mib || used["49"] < 24*mib || used["49"] >= 40*mib {
		t.Fatalf("the idle spawn uses %.0f bytes and the one that wrote 24 MiB of tmpfs %.0f", used["48"], used["49"])
	}

	k.release(t, idle)
	k.release(t, writer)
	k.replies(t, idle, writer)
	if m := k.measure(t, "49"); m["code"] != protocol.CodeUnmeasured {
		t.Fatalf("a retired spawn's place was measured %v", m)
	}
}

// A file's cache is no use of the session that read it, read or mapped as a
// program's code is, whatever the kernel's reclaim makes of it; a tmpfs's
// pages, which only a write can free, are.
func TestAFileReaderIsNotChargedItsCacheAndATmpfsWriterIsChargedItsPages(t *testing.T) {
	const mib = 1 << 20
	k := boundedKeeper(t)
	var fs unix.Statfs_t
	disk := filepath.Dir(k.homes)
	if err := unix.Statfs(disk, &fs); err != nil || int64(fs.Type) == unix.TMPFS_MAGIC {
		t.Fatalf("no disk to keep a file's cache of: %v", err)
	}
	uncached := func(name string) string {
		path := filepath.Join(disk, name)
		file, err := os.Create(path)
		if err != nil {
			t.Fatal(err)
		}
		defer file.Close()
		if _, err := file.Write(make([]byte, 64*mib)); err != nil {
			t.Fatal(err)
		}
		if err := file.Sync(); err != nil {
			t.Fatal(err)
		}
		// Out of the cache, so that the session is the one charged it.
		if err := unix.Fadvise(int(file.Fd()), 0, 0, unix.FADV_DONTNEED); err != nil {
			t.Fatal(err)
		}
		return path
	}
	written, err := os.CreateTemp("/dev/shm", "cyfr-written-")
	if err != nil {
		t.Fatal(err)
	}
	_ = written.Close()
	t.Cleanup(func() { _ = os.Remove(written.Name()) })

	measured := func(id string, uid int, script, counter string, atLeast int) float64 {
		group, err := k.s.memory.Create(cgroup.Name(uid), 256*mib, protocol.CPUPeriod)
		if err != nil {
			t.Fatal(err)
		}
		if placed := k.place(t, id, protocol.KindProgram); placed["type"] != protocol.TypePlaced {
			t.Fatalf("place %s: %v", id, placed)
		}
		k.spawnedIn(t, id, &spawn{id: id, group: group})
		t.Cleanup(func() {
			k.s.mu.Lock()
			delete(k.s.spawns, id)
			k.s.mu.Unlock()
			group.Kill(0)
			if err := group.Remove(); err != nil {
				t.Error(err)
			}
		})
		_, dir := k.runIn(t, group, script)
		// The kernel's own count says when the pages are the group's.
		for deadline := time.Now().Add(30 * time.Second); ; time.Sleep(100 * time.Millisecond) {
			stat, err := os.ReadFile(filepath.Join(dir, "memory.stat"))
			if err != nil {
				t.Fatal(err)
			}
			var pages int
			for _, line := range strings.Split(string(stat), "\n") {
				if value, ok := strings.CutPrefix(line, counter+" "); ok {
					_, _ = fmt.Sscan(value, &pages)
				}
			}
			if pages >= atLeast {
				break
			}
			if time.Now().After(deadline) {
				t.Fatalf("the group was never charged its %s:\n%s", counter, stat)
			}
		}
		// Time to be taken as hot by a reclaim that ages what is mapped.
		time.Sleep(time.Second)
		k.s.read()()
		m := k.measure(t, id)
		bytes, ok := m["bytes"].(float64)
		if !ok {
			t.Fatalf("measuring %s answered %v", id, m)
		}
		return bytes
	}

	// Read again and again: active, and so charged by memory.current less
	// inactive_file, where MGLRU is off.
	read := uncached("read")
	reader := measured(strings.Repeat("c", 32), testPoolFirst,
		"for i in 1 2 3; do cat "+read+" > /dev/null; done; exec sleep 60", "file", 56*mib)
	if reader >= 24*mib {
		t.Errorf("a session that only reads a 64 MiB file uses %.0f bytes", reader)
	}
	// Faulted in cold, as a program's code is: active on any kernel.
	code := uncached("code")
	program := measured(strings.Repeat("b", 32), testPoolLast,
		"exec "+k.s.self+" mapped "+code+" 60", "file_mapped", 56*mib)
	if program >= 24*mib {
		t.Errorf("a session whose program maps 64 MiB of code from a file uses %.0f bytes", program)
	}
	writer := measured(strings.Repeat("d", 32), testPoolLast+1,
		"head -c 33554432 /dev/zero > "+written.Name()+" && exec sleep 60", "shmem", 30*mib)
	if writer < 30*mib || writer >= 48*mib {
		t.Errorf("a session that wrote 32 MiB of tmpfs uses %.0f bytes", writer)
	}
}

// A group killed for a limit above it while under its own bound was ended
// by the machine, where one at its own bound is ended by its cap. The limit
// above is a group of the test's own, standing in for the container's.
func TestAKillForALimitAboveTheSpawnsIsTheMachines(t *testing.T) {
	k := boundedKeeper(t)
	for i, c := range []struct {
		name         string
		above, bound uint64
		failedBefore bool
		want         string
	}{
		{name: "machine", above: 32 << 20, bound: 256 << 20, want: protocol.MemoryMachine},
		{name: "cap", above: 256 << 20, bound: 32 << 20, want: protocol.MemoryCap},
		{name: "machine after the bound failed with nothing to kill", above: 32 << 20, bound: 256 << 20, failedBefore: true, want: protocol.MemoryMachine},
		{name: "cap after the bound failed with nothing to kill", above: 256 << 20, bound: 32 << 20, failedBefore: true, want: protocol.MemoryCap},
	} {
		t.Run(c.name, func(t *testing.T) {
			above := filepath.Join(cgroup.Root, fmt.Sprintf("above-%d-%d", os.Getpid(), i))
			if err := os.Mkdir(above, 0o755); err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() {
				_ = os.Remove(filepath.Join(above, "keeper"))
				if err := os.Remove(above); err != nil {
					t.Error(err)
				}
			})
			for file, value := range map[string]string{"memory.max": fmt.Sprint(c.above), "memory.swap.max": "0"} {
				if err := os.WriteFile(filepath.Join(above, file), []byte(value), 0o644); err != nil {
					t.Fatal(err)
				}
			}
			under, err := cgroup.Delegate(above, []byte("0::/\n"))
			if err != nil {
				t.Fatal(err)
			}
			group, err := under.Create(cgroup.Name(testPoolFirst), c.bound, protocol.CPUPeriod)
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() {
				group.Kill(0)
				if err := group.Remove(); err != nil {
					t.Error(err)
				}
			})

			if c.failedBefore {
				k.failAtItsBound(t, group, c.bound)
			}
			leader, _ := k.runIn(t, group, "exec "+k.s.self+" hold 128 60")
			k.awaitExit(t, leader)
			got := "neither"
			if end := k.s.memoryEnd(&spawn{id: "above", group: group}); end != nil {
				got = *end
			}
			if got != c.want {
				t.Fatalf("a spawn bound at %d bytes under a limit of %d read %q, want %q", c.bound, c.above, got, c.want)
			}
		})
	}
}

// runIn starts a shell as root in the group and lets it run script once it
// is there. It answers the leader and the directory of the cgroup it runs
// in, as /proc names it.
func (k *keeper) runIn(t *testing.T, group *cgroup.Group, script string) (*child, string) {
	t.Helper()
	stdin, start, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer start.Close()
	defer stdin.Close()
	argv := []string{"/bin/sh", "-c", "read go && " + script}
	leader, err := k.s.start(argv[0], argv, nil, []uintptr{stdin.Fd(), 2, 2}, 0, 0, "/")
	if err != nil {
		t.Fatal(err)
	}
	if err := group.Add(leader.pid); err != nil {
		t.Fatal(err)
	}
	in, err := os.ReadFile(fmt.Sprintf("/proc/%d/cgroup", leader.pid))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := start.WriteString("go\n"); err != nil {
		t.Fatal(err)
	}
	return leader, filepath.Join(cgroup.Root, strings.TrimPrefix(strings.TrimSpace(string(in)), "0::"))
}

func (k *keeper) awaitExit(t *testing.T, c *child) {
	t.Helper()
	select {
	case <-c.done:
	case <-time.After(30 * time.Second):
		t.Fatal("no exit within 30 s")
	}
}

// failAtItsBound makes the kernel count an out-of-memory at the group's own
// bound that kills nothing: the bound lowered over tmpfs pages no process
// holds, then given back.
func (k *keeper) failAtItsBound(t *testing.T, group *cgroup.Group, bound uint64) {
	t.Helper()
	file, err := os.CreateTemp("/dev/shm", "cyfr-failed-")
	if err != nil {
		t.Fatal(err)
	}
	_ = file.Close()
	t.Cleanup(func() { _ = os.Remove(file.Name()) })
	writer, dir := k.runIn(t, group, "head -c 8388608 /dev/zero > "+file.Name())
	k.awaitExit(t, writer)
	// os.WriteFile opens a cgroup's file non-blocking, and the kernel then
	// takes a lower memory.max without the reclaim and the OOM it needs.
	set := func(bytes uint64) {
		fd, err := unix.Open(filepath.Join(dir, "memory.max"), unix.O_WRONLY|unix.O_CLOEXEC, 0)
		if err != nil {
			t.Fatal(err)
		}
		defer unix.Close(fd)
		if _, err := unix.Write(fd, []byte(fmt.Sprint(bytes))); err != nil {
			t.Fatal(err)
		}
	}
	set(2 << 20)
	set(bound)
	events, err := os.ReadFile(filepath.Join(dir, "memory.events.local"))
	if err != nil {
		t.Fatal(err)
	}
	counted := map[string]string{}
	for _, line := range strings.Split(strings.TrimSpace(string(events)), "\n") {
		if name, count, ok := strings.Cut(line, " "); ok {
			counted[name] = count
		}
	}
	if counted["oom"] == "0" || counted["oom_kill"] != "0" {
		t.Fatalf("no failure without a kill to start from: %v", counted)
	}
}

// The cause of a kill reaches the client before the release, and is read
// before the counters go, whichever of the leader's watcher and the cleanup
// runs first: here the watcher is held past the cleanup, and in some cases
// the leader's reaping until the cleanup has ended, which waits for it only
// so long.
func TestARetirementLeavesTheCauseOfAKillToBeRead(t *testing.T) {
	for _, c := range []struct {
		name           string
		kept           bool
		watchAtRemoval bool
		reapingHeld    bool
	}{
		{name: "pooled, the watcher held past the whole cleanup"},
		{name: "pooled, the watcher held until the counters are gone", watchAtRemoval: true},
		{name: "pooled, the leader never reaped while the cleanup runs", reapingHeld: true},
		{name: "kept, the watcher held past the whole cleanup", kept: true},
		{name: "kept, the watcher held until the counters are gone", kept: true, watchAtRemoval: true},
		{name: "kept, the leader never reaped while the cleanup runs", kept: true, reapingHeld: true},
	} {
		t.Run(c.name, func(t *testing.T) {
			k, sp, dir := killedAtItsCap(t, c.kept)
			reap := func() {}
			if c.reapingHeld {
				reap = holdReaping(t, sp)
			}

			k.s.retire(sp, 0, true)
			if c.watchAtRemoval {
				for deadline := time.Now().Add(10 * time.Second); ; time.Sleep(5 * time.Millisecond) {
					if _, err := os.Stat(dir); err != nil {
						break
					}
					if time.Now().After(deadline) {
						t.Fatal("the cleanup never removed the counters")
					}
				}
				k.s.watchLeader(sp)
			}
			awaitRetired(t, sp)
			reap()
			// The watcher comes late and has nothing left to add.
			if !c.watchAtRemoval {
				k.s.watchLeader(sp)
			}
			told := k.toldSoFar(t)
			if len(told) != 2 || told[0]["type"] != protocol.TypeExited || told[0]["memory"] != protocol.MemoryCap ||
				told[0]["signal"] != "SIGKILL" || told[1]["type"] != protocol.TypeReleased {
				t.Fatalf("a spawn killed at its cap and retired was told %v; want its exit with cap, then its release", told)
			}
		})
	}
}

// A release is the last word on its spawn: a leader that outlived the
// cleanup's wait for it and was killed for no memory is released with no
// exit, and its watcher, let go afterwards, sends none. Nothing is left to
// read its counters, so its empty group goes.
func TestNothingOfASpawnFollowsItsRelease(t *testing.T) {
	for _, kept := range []bool{false, true} {
		t.Run(fmt.Sprintf("kept %t", kept), func(t *testing.T) {
			k, sp, dir := endedSpawn(t, kept, "exit 0")
			reap := holdReaping(t, sp)

			k.s.retire(sp, 0, true)
			awaitRetired(t, sp)
			if _, err := os.Stat(dir); err == nil {
				t.Error("the released spawn's empty group was left in place")
			}
			reap()
			k.s.watchLeader(sp)

			if told := k.toldSoFar(t); len(told) != 1 || told[0]["type"] != protocol.TypeReleased {
				t.Fatalf("a spawn released before its leader was reaped was told %v; want its release and nothing after it", told)
			}
		})
	}
}

// holdReaping makes the spawn's reaped leader read as one not reaped yet,
// until the function it answers is called.
func holdReaping(t *testing.T, sp *spawn) func() {
	reaped := sp.leader
	held := &child{pid: reaped.pid, done: make(chan struct{})}
	sp.leader = held
	reap := sync.OnceFunc(func() {
		held.status = reaped.status
		close(held.done)
	})
	t.Cleanup(reap)
	return reap
}

func awaitRetired(t *testing.T, sp *spawn) {
	t.Helper()
	select {
	case <-sp.retired:
	case <-time.After(10 * time.Second):
		t.Fatal("the cleanup did not finish")
	}
}

// toldSoFar is every line the keeper sent before the call.
func (k *keeper) toldSoFar(t *testing.T) []map[string]any {
	t.Helper()
	k.s.send(protocol.NewPoolReply("after", "runner", 0, 0, 0))
	var told []map[string]any
	for {
		m := k.reply(t)
		if m["id"] == "after" {
			return told
		}
		told = append(told, m)
	}
}

func killedAtItsCap(t *testing.T, kept bool) (*keeper, *spawn, string) {
	t.Helper()
	return endedSpawn(t, kept, "exec exe hold 128 60")
}

// endedSpawn is a spawn, pooled or kept, under a bound of 32 MiB, whose
// leader ran script, ended and was reaped, with no watcher started for it.
// In script "exe" names the keeper's own binary. It answers the directory of
// the spawn's counters too.
func endedSpawn(t *testing.T, kept bool, script string) (*keeper, *spawn, string) {
	t.Helper()
	var k *keeper
	uid := testPoolFirst
	sp := &spawn{id: strings.Repeat("e", 32), retired: make(chan struct{})}
	name := cgroup.Name(uid)
	if kept {
		k = keptKeeper(t)
		uid = testKeptFirst
		sp.kept = true
		sp.account = KeptAccount(uid)
		sp.home = filepath.Join(k.s.cfg.Kept.Root, "vlt_killed")
		if made := k.homeRequest(t, protocol.TypeHomeMake, "killed", sp.home, uid); made["type"] != protocol.TypeHomeMade {
			t.Fatalf("home_make: %v", made)
		}
		name = cgroup.SpawnName(sp.id)
	} else {
		k = boundedKeeper(t)
		sp.pool = k.s.pools["runner"]
		sp.account = k.s.accounts[uid]
	}
	group, err := k.s.memory.Create(name, 32<<20, protocol.CPUPeriod)
	if err != nil {
		t.Fatal(err)
	}
	leader, dir := k.runIn(t, group, strings.ReplaceAll(script, "exe ", k.s.self+" "))
	k.awaitExit(t, leader)
	sp.group, sp.leader = group, leader
	k.s.mu.Lock()
	k.s.spawns[sp.id] = sp
	if kept {
		k.s.keptMaps()
		k.s.keptLive[uid] = 1
		k.s.keptHomes[uid] = sp.home
	}
	k.s.mu.Unlock()
	return k, sp, dir
}
