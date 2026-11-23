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
	"testing"
	"time"

	"github.com/cyfr/locus/keeper/internal/cgroup"
	"github.com/cyfr/locus/keeper/internal/frame"
	"github.com/cyfr/locus/keeper/internal/protocol"
)

// endGrace is the grace these tests end a group within, the kept spawn's
// own (the backends service's stop grace).
const endGrace = 2 * time.Second

// childScript is a child that records each TERM the moment it arrives, as
// "child-signalled <unix seconds>": Perl runs its handler as soon as the
// signal interrupts its sleep, so no foreground command defers it. It says
// "child-ready" once its handler is set, then waits: told by its leader
// (the stop file), it ends after its close's seconds saying "child-clean";
// asked with TERM, it ends after them saying "child-ended", unless it
// ignores TERM. args are its close's seconds and what it does on TERM.
func childScript(args string) string {
	return `perl -MTime::HiRes=time,sleep -e '
		my ($log, $stop, $close, $on) = @ARGV;
		sub out { open my $f, ">>", $log or die; print $f "@_\n"; close $f }
		if ($on eq "ignore") { $SIG{TERM} = "IGNORE" }
		else { $SIG{TERM} = sub { out("child-signalled", time); sleep $close; out("child-ended"); exit 0 } }
		out("child-ready");
		sleep 0.01 until -e $stop;
		sleep $close;
		out("child-clean");' "$L" "$L.stop" ` + args
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

// logged waits until the log holds a line beginning with each of want, and
// answers its lines as their words.
func logged(t *testing.T, log string, want ...string) [][]string {
	t.Helper()
	for deadline := time.Now().Add(10 * time.Second); ; time.Sleep(10 * time.Millisecond) {
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
		missing := false
		for _, w := range want {
			missing = missing || !have[w]
		}
		if !missing || time.Now().After(deadline) {
			return got
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

// exitedAt answers when the keeper reaped c.
func exitedAt(c *child) func() time.Time {
	var at time.Time
	got := make(chan struct{})
	go func() { <-c.done; at = time.Now(); close(got) }()
	return func() time.Time { <-got; return at }
}

// A leader that ends its child on TERM: the child ends as its leader told
// it and is never signalled. On TERM to the whole group at once the child
// is signalled at that instant, before its leader can tell it anything,
// and records it, so the test cannot pass there in any order.
func TestAnEndAsksTheLeaderFirst(t *testing.T) {
	k := boundedKeeper(t)
	leader, group, log := endingGroup(t, k, testPoolFirst,
		childScript("0.2 told")+` &
		 child=$!
		 trap 'touch "$L.stop"; wait $child; echo leader-exits >> "$L"; exit 0' TERM
		 echo leader-ready >> "$L"
		 while :; do sleep 0.05; done`)
	logged(t, log, "child-ready", "leader-ready")
	if !k.s.endInOrder(group, leader, time.Now().Add(endGrace)) {
		t.Fatal("the group outlived its end")
	}
	got := names(logged(t, log, "child-clean", "leader-exits"))
	if !strings.HasSuffix(got, "child-clean leader-exits") || strings.Contains(got, "child-signalled") {
		t.Fatalf("the child was not ended by its leader alone: %q", got)
	}
}

// A leader that exits without telling its child: the child is asked with
// TERM only after the keeper reaped the leader, and has the rest of the
// grace to end. On TERM to the whole group at once the child records its
// TERM at once while the leader exits 0.3 s later, so the test cannot pass
// there in any order.
func TestAChildItsLeaderDidNotTellIsAskedAfterIt(t *testing.T) {
	k := boundedKeeper(t)
	leader, group, log := endingGroup(t, k, testPoolFirst,
		childScript("0.3 asked")+` &
		 trap 'sleep 0.3; exit 0' TERM
		 echo leader-ready >> "$L"
		 while :; do sleep 0.05; done`)
	logged(t, log, "child-ready", "leader-ready")
	reaped := exitedAt(leader)
	if !k.s.endInOrder(group, leader, time.Now().Add(endGrace)) {
		t.Fatal("the group outlived its end")
	}
	lines := logged(t, log, "child-signalled", "child-ended")
	var asked time.Time
	for _, l := range lines {
		if l[0] == "child-signalled" && len(l) > 1 {
			seconds, err := strconv.ParseFloat(l[1], 64)
			if err != nil {
				t.Fatal(err)
			}
			asked = time.Unix(0, int64(seconds*1e9))
		}
	}
	if left := reaped(); asked.IsZero() || !asked.After(left) {
		t.Fatalf("the child was asked at %v, its leader reaped at %v: %q", asked, left, names(lines))
	}
	if got := names(lines); !strings.HasSuffix(got, "child-signalled child-ended") {
		t.Fatalf("the child had no time to end: %q", got)
	}
}

// endSlip is how far past its deadline a group's end may run: cgroup's Kill
// waits in 20 ms polls and confirms its kill with one more.
const endSlip = 100 * time.Millisecond

// A leader that ignores TERM is killed with its group at the grace's end,
// and not later: the grace does not grow.
func TestALeaderThatIgnoresTheEndIsKilledAtTheGracesEnd(t *testing.T) {
	k := boundedKeeper(t)
	leader, group, log := endingGroup(t, k, testPoolFirst,
		childScript("0 ignore")+` &
		 trap '' TERM
		 echo leader-ready >> "$L"
		 while :; do sleep 0.05; done`)
	logged(t, log, "child-ready", "leader-ready")
	started := time.Now()
	if !k.s.endInOrder(group, leader, started.Add(endGrace)) {
		t.Fatal("the group outlived its end")
	}
	if took := time.Since(started); took < endGrace || took > endGrace+endSlip {
		t.Fatalf("the group was killed after %s, not at its grace's end, %s", took, endGrace)
	}
	if pids, err := group.Procs(); err != nil || len(pids) != 0 {
		t.Fatalf("the group holds %v after its end (%v)", pids, err)
	}
	k.awaitExit(t, leader)
}

// Two sessions of one kept home, a slow closer released first and a fast
// one second: the fast one's end does not cut the slow one's short, since
// the uid's full retirement, which kills every process of it, waits for
// every session of it to end its own group. When each session left the
// count at its release, the fast one became the last and killed the slow
// one's child while it was still closing.
func TestTwoSessionsOfOneHomeEachEndInTheirOwnTime(t *testing.T) {
	k := keptKeeper(t)
	uid := testKeptFirst
	home := filepath.Join(k.s.cfg.Kept.Root, "vlt_end-order")
	if made := k.homeRequest(t, protocol.TypeHomeMake, "m", home, uid); made["type"] != protocol.TypeHomeMade {
		t.Fatalf("home_make: %v", made)
	}
	log := filepath.Join(home, "log")
	slow, _ := k.spawnKept(t, "slow", `L="$HOME/log"; `+childScript("1 told")+` &
		 child=$!
		 trap 'touch "$L.stop"; wait $child; echo leader-exits >> "$L"; exit 0' TERM
		 echo leader-ready >> "$L"
		 while :; do sleep 0.05; done`, home, uid)
	fast, rc := k.spawnKept(t, "fast", `echo fast-ready; while :; do sleep 0.05; done`, home, uid)
	rc.readUntil(t, func() bool { return strings.Contains(string(rc.got[frame.StreamStdout]), "fast-ready") })
	logged(t, log, "child-ready", "leader-ready")

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
	got := names(logged(t, log, "child-clean", "leader-exits"))
	if !strings.HasSuffix(got, "child-clean leader-exits") || strings.Contains(got, "child-signalled") {
		t.Fatalf("the slow session's child was cut short by the other's end: %q", got)
	}
	if retired := k.homeRequest(t, protocol.TypeHomeRetire, "r", home, uid); retired["type"] != protocol.TypeHomeRetired {
		t.Fatalf("home_retire: %v", retired)
	}
}
