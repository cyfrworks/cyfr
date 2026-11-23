// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package serve

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/cyfr/locus/keeper/internal/cgroup"
	"github.com/cyfr/locus/keeper/internal/protocol"
)

// endGrace is the grace these tests end a group within, the kept spawn's
// own (the backends service's stop grace).
const endGrace = 2 * time.Second

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

// lines waits until the log holds want lines, and answers them.
func lines(t *testing.T, log string, want int) []string {
	t.Helper()
	for deadline := time.Now().Add(5 * time.Second); ; time.Sleep(10 * time.Millisecond) {
		data, err := os.ReadFile(log)
		if err != nil {
			t.Fatal(err)
		}
		got := strings.Fields(string(data))
		if len(got) >= want || time.Now().After(deadline) {
			return got
		}
	}
}

// A leader that closes its child on TERM: the child ends as its leader
// told it, and is never signalled before its leader exits.
func TestAnEndAsksTheLeaderFirst(t *testing.T) {
	k := boundedKeeper(t)
	leader, group, log := endingGroup(t, k, testPoolFirst,
		`sh -c 'trap "echo child-signalled >> $0; exit 1" TERM; echo child-ready >> $0; while [ ! -e $0.stop ]; do sleep 0.02; done; echo child-clean >> $0' "$L" &
		 child=$!
		 trap 'touch "$L.stop"; wait $child; echo leader-exits >> "$L"; exit 0' TERM
		 while :; do sleep 0.05; done`)
	if got := lines(t, log, 1); len(got) != 1 || got[0] != "child-ready" {
		t.Fatalf("the child did not start: %q", got)
	}
	if !endInOrder(group, leader, endGrace) {
		t.Fatal("the group outlived its end")
	}
	if got := lines(t, log, 3); strings.Join(got, " ") != "child-ready child-clean leader-exits" {
		t.Fatalf("the child was not ended by its leader alone: %q", got)
	}
}

// A leader that exits without telling its child: once the leader has
// exited, the child is asked with TERM and has the rest of the grace to
// end itself.
func TestAChildItsLeaderDidNotTellIsAskedAfterIt(t *testing.T) {
	k := boundedKeeper(t)
	leader, group, log := endingGroup(t, k, testPoolFirst,
		`sh -c 'trap "echo child-asked >> $0; sleep 0.3; echo child-ended >> $0; exit 0" TERM; echo child-ready >> $0; while :; do sleep 0.05; done' "$L" &
		 trap 'sleep 0.3; echo leader-exits >> "$L"; exit 0' TERM
		 while :; do sleep 0.05; done`)
	if got := lines(t, log, 1); len(got) != 1 || got[0] != "child-ready" {
		t.Fatalf("the child did not start: %q", got)
	}
	if !endInOrder(group, leader, endGrace) {
		t.Fatal("the group outlived its end")
	}
	if got := lines(t, log, 4); strings.Join(got, " ") != "child-ready leader-exits child-asked child-ended" {
		t.Fatalf("the child was not asked after its leader exited, or had no time to end: %q", got)
	}
}

// A leader that ignores TERM is killed with its group at the grace's end,
// and not later: the grace does not grow.
func TestALeaderThatIgnoresTheEndIsKilledAtTheGracesEnd(t *testing.T) {
	k := boundedKeeper(t)
	leader, group, log := endingGroup(t, k, testPoolFirst,
		`sh -c 'trap "" TERM; echo child-ready >> $0; while :; do sleep 0.05; done' "$L" &
		 trap '' TERM
		 while :; do sleep 0.05; done`)
	if got := lines(t, log, 1); len(got) != 1 || got[0] != "child-ready" {
		t.Fatalf("the child did not start: %q", got)
	}
	started := time.Now()
	if !endInOrder(group, leader, endGrace) {
		t.Fatal("the group outlived its end")
	}
	took := time.Since(started)
	if took < endGrace || took > endGrace+time.Second {
		t.Fatalf("the group was killed after %s, not at its grace's end, %s", took, endGrace)
	}
	if pids, err := group.Procs(); err != nil || len(pids) != 0 {
		t.Fatalf("the group holds %v after its end (%v)", pids, err)
	}
	k.awaitExit(t, leader)
}
