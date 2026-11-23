// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package serve

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/cyfr/locus/keeper/internal/cgroup"
	"github.com/cyfr/locus/keeper/internal/protocol"
)

// endGrace is the grace these tests end a group within, the kept spawn's
// own (the backends service's stop grace).
const endGrace = 2 * time.Second

// blockingChild is a child that blocks TERM, so a TERM sent to it stays
// pending, which /proc/<pid>/status shows: the test reads from the kernel
// whether TERM has reached it, with no clock. It says "child-ready <pid>"
// once TERM is blocked. Told by its leader (the stop file), it ends after
// close seconds saying "child-clean"; once TERM is pending, it says
// "child-asked", ends after close seconds saying "child-ended".
func blockingChild(close string) string {
	return `perl -MPOSIX -MTime::HiRes=sleep -e '
		my ($log, $stop, $close) = @ARGV;
		sub out { open my $f, ">>", $log or die; print $f "@_\n"; close $f }
		POSIX::sigprocmask(POSIX::SIG_BLOCK(), POSIX::SigSet->new(POSIX::SIGTERM())) or die;
		out("child-ready", $$);
		while (1) {
			if (-e $stop) { sleep $close; out("child-clean"); exit 0 }
			my $pending = POSIX::SigSet->new; POSIX::sigpending($pending);
			if ($pending->ismember(POSIX::SIGTERM())) { out("child-asked"); sleep $close; out("child-ended"); exit 0 }
			sleep 0.01;
		}' "$L" "$L.stop" ` + close
}

// heldLeader is a leader's script around its child (run in the background
// before it): on TERM it says "leader-got-term" and waits for the test's
// word, the go file, before it does what then does and exits.
func heldLeader(then string) string {
	return ` &
		 child=$!
		 trap 'echo leader-got-term >> "$L"; while [ ! -e "$L.go" ]; do sleep 0.01; done; ` + then + `; echo leader-exits >> "$L"; exit 0' TERM
		 echo leader-ready >> "$L"
		 while :; do sleep 0.05; done`
}

// endingGroup runs script as the leader of a bounded group of its own and
// answers the leader, the group and a log file the script writes to as $L.
func endingGroup(t *testing.T, k *keeper, uid int, script string) (*child, *cgroup.Group, string) {
	t.Helper()
	group, err := k.s.memory.Create(cgroup.Name(uid), 256<<20, protocol.CPUPeriod)
	if err != nil {
		t.Fatal(err)
	}
	log := filepath.Join(t.TempDir(), "log")
	if err := os.WriteFile(log, nil, 0o666); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		group.Kill(0)
		if err := group.Remove(); err != nil {
			t.Error(err)
		}
	})
	leader, _ := k.runIn(t, group, "L="+log+"; "+script)
	return leader, group, log
}

// logged waits until the log holds a line beginning with each of want and
// answers its lines as their words; a line that never comes fails the test.
func logged(t *testing.T, log string, want ...string) [][]string {
	t.Helper()
	for deadline := time.Now().Add(20 * time.Second); ; time.Sleep(10 * time.Millisecond) {
		data, err := os.ReadFile(log)
		if err != nil && !os.IsNotExist(err) {
			t.Fatal(err)
		}
		var got [][]string
		have := map[string]bool{}
		for _, line := range strings.Split(string(data), "\n") {
			if fields := strings.Fields(line); len(fields) > 0 {
				got = append(got, fields)
				have[fields[0]] = true
			}
		}
		var missing []string
		for _, w := range want {
			if !have[w] {
				missing = append(missing, w)
			}
		}
		if len(missing) == 0 {
			return got
		}
		if time.Now().After(deadline) {
			t.Fatalf("%v never came: %q", missing, names(got))
		}
	}
}

// names are the lines' first words, in their order.
func names(lines [][]string) string {
	var out []string
	for _, l := range lines {
		out = append(out, l[0])
	}
	return strings.Join(out, " ")
}

// childPID is the pid the child said it is.
func childPID(t *testing.T, lines [][]string) int {
	t.Helper()
	for _, l := range lines {
		if l[0] == "child-ready" && len(l) > 1 {
			pid, err := strconv.Atoi(l[1])
			if err != nil {
				t.Fatal(err)
			}
			return pid
		}
	}
	t.Fatal("the child named no pid")
	return 0
}

// termReached says whether TERM has reached the child of pid: a TERM
// pending on it, which blocks TERM, read from the kernel's own record, or
// its log's word that it saw one and is ending, or its end.
func termReached(t *testing.T, log string, pid int) bool {
	t.Helper()
	data, err := os.ReadFile(fmt.Sprintf("/proc/%d/status", pid))
	if err != nil {
		return true
	}
	if lines, _ := os.ReadFile(log); strings.Contains(string(lines), "child-asked") {
		return true
	}
	for _, line := range strings.Split(string(data), "\n") {
		name, value, _ := strings.Cut(line, ":")
		if name != "SigPnd" && name != "ShdPnd" {
			continue
		}
		mask, err := strconv.ParseUint(strings.TrimSpace(value), 16, 64)
		if err != nil {
			t.Fatal(err)
		}
		if mask&(1<<(uint(syscall.SIGTERM)-1)) != 0 {
			return true
		}
	}
	return false
}

// ending runs endInOrder on the group in the background and answers a
// channel that carries whether the group was empty when it returned.
func ending(k *keeper, group *cgroup.Group, leader *child) chan bool {
	ended := make(chan bool, 1)
	go func() { ended <- k.s.endInOrder(group, leader, time.Now().Add(endGrace)) }()
	return ended
}

// A leader that ends its child on TERM: while the leader holds its TERM the
// child has no TERM pending, and it ends as its leader told it. On TERM to
// the whole group at once, Group.Signal sends TERM to every process of it
// in one loop before the leader's trap has run and written its word, so the
// child's TERM is already pending when the test reads it, in any order.
func TestAnEndAsksTheLeaderFirst(t *testing.T) {
	k := boundedKeeper(t)
	leader, group, log := endingGroup(t, k, testPoolFirst, blockingChild("0")+heldLeader(`touch "$L.stop"; wait $child`))
	child := childPID(t, logged(t, log, "child-ready", "leader-ready"))
	ended := ending(k, group, leader)
	logged(t, log, "leader-got-term")
	if termReached(t, log, child) {
		t.Fatal("TERM reached the child while its leader was still ending")
	}
	if err := os.WriteFile(log+".go", nil, 0o666); err != nil {
		t.Fatal(err)
	}
	if !<-ended {
		t.Fatal("the group outlived its end")
	}
	if got := names(logged(t, log, "child-clean", "leader-exits")); strings.Contains(got, "child-asked") {
		t.Fatalf("the child was asked to end, not told by its leader: %q", got)
	}
}

// A leader that exits without telling its child: while the leader holds
// its TERM the child has no TERM pending; once the leader has exited, TERM
// reaches the child, which has the rest of the grace to end. On TERM to
// the whole group at once the child's TERM is pending while the leader is
// held, so the test cannot pass there in any order.
func TestAChildItsLeaderDidNotTellIsAskedAfterIt(t *testing.T) {
	k := boundedKeeper(t)
	leader, group, log := endingGroup(t, k, testPoolFirst, blockingChild("0.3")+heldLeader(`:`))
	child := childPID(t, logged(t, log, "child-ready", "leader-ready"))
	ended := ending(k, group, leader)
	logged(t, log, "leader-got-term")
	if termReached(t, log, child) {
		t.Fatal("TERM reached the child before its leader exited")
	}
	if err := os.WriteFile(log+".go", nil, 0o666); err != nil {
		t.Fatal(err)
	}
	if !<-ended {
		t.Fatal("the group outlived its end")
	}
	if got := names(logged(t, log, "leader-exits", "child-asked", "child-ended")); !strings.HasSuffix(got, "child-asked child-ended") {
		t.Fatalf("the child was not asked after its leader, or had no time to end: %q", got)
	}
}

// A leader that ignores TERM is killed with its group at the grace's end:
// the group is empty when the end returns, and it did not return before
// the grace's end. KillBy waits until the deadline and no longer, and
// sends its kill within one 20 ms poll of it; the ceiling here is loose,
// so as not to fail under load.
func TestALeaderThatIgnoresTheEndIsKilledAtTheGracesEnd(t *testing.T) {
	k := boundedKeeper(t)
	leader, group, log := endingGroup(t, k, testPoolFirst,
		`perl -e '$SIG{TERM} = "IGNORE"; open my $f, ">>", $ARGV[0]; print $f "child-ready\n"; close $f; sleep 600' "$L" &
		 trap '' TERM
		 echo leader-ready >> "$L"
		 while :; do sleep 0.05; done`)
	logged(t, log, "child-ready", "leader-ready")
	started := time.Now()
	if !k.s.endInOrder(group, leader, started.Add(endGrace)) {
		t.Fatal("the group outlived its end")
	}
	if took := time.Since(started); took < endGrace || took > endGrace+time.Second {
		t.Fatalf("the group was killed after %s, not at its grace's end, %s", took, endGrace)
	}
	if pids, err := group.Procs(); err != nil || len(pids) != 0 {
		t.Fatalf("the group holds %v after its end (%v)", pids, err)
	}
	k.awaitExit(t, leader)
}

// Two sessions of one kept home, a slow closer released first and a fast
// one second: the fast one's end does not cut the slow one's short, since
// the uid's full retirement, which kills every process of it, runs only
// once no session of it is still ending. When the last release ran it at
// once, it killed the slow one's child while it was still closing.
func TestTwoSessionsOfOneHomeEachEndInTheirOwnTime(t *testing.T) {
	k := keptKeeper(t)
	uid := testKeptFirst
	home := filepath.Join(k.s.cfg.Kept.Root, "vlt_end-order")
	if made := k.homeRequest(t, protocol.TypeHomeMake, "m", home, uid); made["type"] != protocol.TypeHomeMade {
		t.Fatalf("home_make: %v", made)
	}
	log := filepath.Join(home, "log")
	slow, _ := k.spawnKept(t, "slow", `L="$HOME/log"; `+blockingChild("1")+` &
		 child=$!
		 trap 'touch "$L.stop"; wait $child; echo leader-exits >> "$L"; exit 0' TERM
		 echo leader-ready >> "$L"
		 while :; do sleep 0.05; done`, home, uid)
	fast, _ := k.spawnKept(t, "fast", `echo fast-ready >> "$HOME/log"; while :; do sleep 0.05; done`, home, uid)
	logged(t, log, "child-ready", "leader-ready", "fast-ready")

	grace := endGrace.Milliseconds()
	for _, spawnID := range []string{slow, fast} {
		k.s.handleRelease(&protocol.Request{V: protocol.Version, Type: protocol.TypeRelease, SpawnID: spawnID, GraceMs: &grace})
	}
	released := map[string]bool{}
	for len(released) < 2 {
		if m := k.reply(t); m["type"] == protocol.TypeReleased {
			released[fmt.Sprint(m["spawn_id"])] = true
		}
	}
	if got := names(logged(t, log, "child-clean", "leader-exits")); strings.Contains(got, "child-asked") {
		t.Fatalf("the slow session's child was asked to end by the other's end: %q", got)
	}
	if retired := k.homeRequest(t, protocol.TypeHomeRetire, "r", home, uid); retired["type"] != protocol.TypeHomeRetired {
		t.Fatalf("home_retire: %v", retired)
	}
}

// The release of a home's only session marks its uid retiring at once: while
// that session is still ending, a home_make of the home is refused and a
// spawn of it waits for the uid's retirement, as for any retiring uid, and
// another home is unaffected. A newcomer is never admitted beside a uid
// whose last session is ending.
func TestANewcomerWaitsForTheLastSessionsEnd(t *testing.T) {
	k := keptKeeper(t)
	uid := testKeptFirst
	home := filepath.Join(k.s.cfg.Kept.Root, "vlt_newcomer")
	other := filepath.Join(k.s.cfg.Kept.Root, "vlt_newcomer-other")
	if made := k.homeRequest(t, protocol.TypeHomeMake, "m", home, uid); made["type"] != protocol.TypeHomeMade {
		t.Fatalf("home_make: %v", made)
	}
	log := filepath.Join(home, "log")
	only, _ := k.spawnKept(t, "only", `L="$HOME/log"; sleep 600`+heldLeader(`:`), home, uid)
	logged(t, log, "leader-ready")
	grace := endGrace.Milliseconds()
	k.s.handleRelease(&protocol.Request{V: protocol.Version, Type: protocol.TypeRelease, SpawnID: only, GraceMs: &grace})
	logged(t, log, "leader-got-term")

	if busy := k.homeRequest(t, protocol.TypeHomeMake, "m2", home, uid); busy["code"] != protocol.CodeUIDBusy {
		t.Fatalf("home_make of the home while its last session ends: %v", busy)
	}
	k.s.mu.Lock()
	retiring, busy := k.s.keptState(uid, home)
	k.s.mu.Unlock()
	if retiring == nil || busy {
		t.Fatalf("a spawn of the home while its last session ends would not wait for its retirement: %v %v", retiring, busy)
	}
	if made := k.homeRequest(t, protocol.TypeHomeMake, "m3", other, uid+1); made["type"] != protocol.TypeHomeMade {
		t.Fatalf("home_make of another home: %v", made)
	}

	if placed := k.place(t, "newcomer", protocol.KindProgram); placed["type"] != protocol.TypePlaced {
		t.Fatalf("the newcomer's place answered %v", placed)
	}
	go k.s.handleSpawn(keptRequest(t, k.attach, "newcomer", `echo newcomer-started >> "$HOME/log"; sleep 600`, home, uid, nil))
	if err := os.WriteFile(log+".go", nil, 0o666); err != nil {
		t.Fatal(err)
	}
	var newcomer string
	for newcomer == "" {
		m := k.reply(t)
		if m["type"] == protocol.TypeError {
			t.Fatalf("the newcomer was refused: %v", m)
		}
		if m["type"] == protocol.TypeSpawned {
			newcomer = m["spawn_id"].(string)
		}
	}
	k.accept(t)
	if got := names(logged(t, log, "leader-exits", "newcomer-started")); !strings.HasSuffix(got, "leader-exits newcomer-started") {
		t.Fatalf("the newcomer started before the last session ended: %q", got)
	}
	zero := int64(0)
	k.s.handleRelease(&protocol.Request{V: protocol.Version, Type: protocol.TypeRelease, SpawnID: newcomer, GraceMs: &zero})
}
