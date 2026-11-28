// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package serve

import (
	"errors"
	"testing"
	"time"

	"github.com/cyfr/locus/keeper/guard"
	"github.com/cyfr/locus/keeper/internal/cgroup"
	"github.com/cyfr/locus/keeper/internal/protocol"
	"github.com/cyfr/locus/keeper/internal/vm"
)

// A VM's release waits for its route's withdrawal on the guard's word, and
// a clear the guard refuses at the VM's end is asked again at each sweep:
// the sweep that clears it releases the VM, and the person's next VM boots
// then, never before and never four minutes later.

// released says m has been released.
func released(m *machine) bool {
	select {
	case <-m.done:
		return true
	default:
		return false
	}
}

// sweepRoutes is the part of a sweep with a guard that settles VMs'
// routes (sweep).
func sweepRoutes(s *server) {
	s.retryClears()
	s.retryNarrowing()
	s.finishMachines()
	s.endIdleMachines()
}

// @Opus2's (4521 fail 2): a VM killed at rest whose clear is refused once.
func TestAVMWhoseClearWasRefusedOnceIsReleasedBySweeps(t *testing.T) {
	k := newVMKeeper(t)
	k.disk(t, "ath_a", "vlt_a1")
	id, _ := k.session(t, "s1", "ath_a", "vlt_a1", nil)
	ms := int64(0)
	k.s.handle(k.c, &protocol.Request{V: protocol.Version, Type: protocol.TypeRelease, SpawnID: id, GraceMs: &ms})
	k.expect(t, "released")
	m := k.machineOfAthanor("ath_a")
	k.guard.mu.Lock()
	k.guard.refuseClears = 1
	k.guard.mu.Unlock()
	k.guest.booted()[0].Kill()
	vmEventually(t, "the VM's clear asked", func() bool {
		for _, c := range k.guard.taken() {
			if c.op == guard.TypeClear && c.spawnID == m.id {
				return true
			}
		}
		return false
	})
	for i := 0; i < 5; i++ {
		sweepRoutes(k.s)
	}
	select {
	case <-m.done:
	case <-time.After(3 * time.Second):
		k.s.mu.Lock()
		held, ending, used := m.route != nil, k.s.vmsEnding[m], k.s.ledger.Report("backends", 0, now()).Used
		k.s.mu.Unlock()
		t.Fatalf("the VM was never released after its route's clear succeeded on a sweep (route held %t, still ending %t, pool used %d)", held, ending, used)
	}
}

// @Fable3's (4742 fail 2): a VM whose VMM exits under a session, its clear
// refused once: released, and nothing of it charged, once a sweep clears.
func TestAVMWhoseClearWasRefusedOnceIsReleasedByALaterSweep(t *testing.T) {
	k := newVMKeeper(t)
	k.disk(t, "ath_a", "vlt_a1", "vlt_a2")
	k.session(t, "s1", "ath_a", "vlt_a1", nil)
	m := k.machineOfAthanor("ath_a")
	k.guard.mu.Lock()
	k.guard.refuseClears = 1
	k.guard.mu.Unlock()
	k.guest.booted()[0].end(vm.EndOwnExit, cgroup.NotKilled)
	k.expect(t, "exited")
	k.expect(t, "released")
	vmEventually(t, "the refused clear's record", func() bool {
		k.s.mu.Lock()
		defer k.s.mu.Unlock()
		_, held := k.s.uncleared[m.id]
		return held
	})
	for i := 0; i < 3; i++ {
		k.s.retryClears()
		k.s.finishMachines()
	}
	k.s.mu.Lock()
	_, uncleared := k.s.uncleared[m.id]
	used := k.s.ledger.Report("backends", 0, now()).Used
	k.s.mu.Unlock()
	if uncleared {
		t.Fatal("the guard never cleared the route: the test's premise does not hold")
	}
	if !released(m) || used != 0 {
		t.Fatalf("a VM whose route the guard cleared at a later sweep is not released: released %t, the pool still holds %d bytes of it", released(m), used)
	}
}

// A VM whose clear the guard refused is not released before a sweep clears
// it, its charge held; the person's next start waits for that release, and
// boots its VM at the sweep that gives it.
func TestTheNextVMBootsAtTheLastOnesReleaseAndNotBefore(t *testing.T) {
	k := newVMKeeper(t)
	k.disk(t, "ath_a", "vlt_a1", "vlt_a2")
	k.session(t, "s1", "ath_a", "vlt_a1", nil)
	m := k.machineOfAthanor("ath_a")
	k.guard.mu.Lock()
	k.guard.refuseClears = 1
	k.guard.mu.Unlock()
	k.guest.booted()[0].end(vm.EndOwnExit, cgroup.NotKilled)
	k.expect(t, "exited")
	k.expect(t, "released")
	vmEventually(t, "the refused clear's record", func() bool {
		k.s.mu.Lock()
		defer k.s.mu.Unlock()
		_, held := k.s.uncleared[m.id]
		return held
	})
	k.s.finishMachines()
	k.s.mu.Lock()
	used := k.s.ledger.Report("backends", 0, now()).Used
	k.s.mu.Unlock()
	if released(m) || used == 0 {
		t.Fatalf("a VM whose route the guard has not cleared was released %t, the pool holding %d bytes of it", released(m), used)
	}
	k.place(t, "p-s2", "ath_a")
	next := k.machineOfAthanor("ath_a")
	if next == m || next.prev != m {
		t.Fatal("the person's next place names the VM still ending, or one that does not follow it")
	}
	go k.s.handleSpawn(k.c, k.spawnReq("s2", "p-s2", "vlt_a2", nil))
	vmEventually(t, "the next VM's boot waiting", func() bool {
		k.s.mu.Lock()
		defer k.s.mu.Unlock()
		return next.booting
	})
	time.Sleep(200 * time.Millisecond) // sleep-ok: a boot that did not wait for the last VM's release would have begun
	if n := len(k.guest.booted()); n != 1 {
		t.Fatalf("the person's next VM booted beside the last one still ending: %d VMs", n)
	}
	sweepRoutes(k.s)
	if got := k.expect(t, "spawned"); got["id"] != "s2" {
		t.Fatalf("the next start answered %v", got)
	}
	if !released(m) || len(k.guest.booted()) != 2 {
		t.Fatalf("the next start: the last VM released %t, %d VMs booted", released(m), len(k.guest.booted()))
	}
}

// @Fable3's (5499's first note): a VM's boot fails after its route is made and the guard
// refuses the clear; the next start's boot fails too and its withdrawal is
// answered; the third boots. All three are of one machine, so of one route
// id. What does the next sweep's retry of the first clear do to the running
// VM's route?
func TestAStaleClearDoesNotTakeARebootedVMsRoute(t *testing.T) {
	k := newVMKeeper(t)
	k.disk(t, "ath_a", "vlt_a1", "vlt_a2", "vlt_a3")
	for _, id := range []string{"p-s1", "p-s2", "p-s3"} {
		k.place(t, id, "ath_a")
	}
	m := k.machineOfAthanor("ath_a")
	k.guest.mu.Lock()
	k.guest.refuseBoot = errors.New("the VMM's space did not start")
	k.guest.mu.Unlock()
	k.guard.mu.Lock()
	k.guard.refuseClears = 1
	k.guard.mu.Unlock()
	for _, id := range []string{"s1", "s2"} {
		k.s.handleSpawn(k.c, k.spawnReq(id, "p-"+id, "vlt_a"+id[1:], nil))
		if got := k.next(t); got["type"] != "error" {
			t.Fatalf("start %s of a VM that does not start answered %v", id, got)
		}
	}
	k.s.mu.Lock()
	_, stale := k.s.uncleared[m.id]
	heldNow := m.route != nil
	k.s.mu.Unlock()
	k.guest.mu.Lock()
	k.guest.refuseBoot = nil
	k.guest.mu.Unlock()
	k.s.handleSpawn(k.c, k.spawnReq("s3", "p-s3", "vlt_a3", nil))
	k.expect(t, "spawned")
	same := k.machineOfAthanor("ath_a") == m
	k.s.mu.Lock()
	before := m.route != nil
	k.s.mu.Unlock()
	k.s.retryClears()
	k.s.mu.Lock()
	after := m.route != nil
	sessions := len(m.sessions)
	k.s.mu.Unlock()
	clears := 0
	for _, c := range k.guard.taken() {
		if c.op == "clear" && c.spawnID == m.id {
			clears++
		}
	}
	t.Logf("after two failed boots: a clear still owed %t, the route held %t; the third boot: same machine %t, its route held %t; after the sweep's retry: held %t, %d sessions in the VM, %d clears asked of its id",
		stale, heldNow, same, before, after, sessions, clears)
	if same && before && !after {
		t.Fatalf("the sweep's retry of an earlier boot's clear was asked of the running VM's route id and let the keeper's hold on it go, %d sessions in the VM", sessions)
	}
}

// A clear retried for a boot whose VM did not start is asked of that boot's
// route alone: the person's VM booted next has a route id of its own, which
// the retry never names, and its hold stays.
func TestARetriedClearIsForItsOwnBootsRoute(t *testing.T) {
	k := newVMKeeper(t)
	k.disk(t, "ath_a", "vlt_a1", "vlt_a2")
	k.place(t, "p-s1", "ath_a")
	k.place(t, "p-s2", "ath_a")
	m := k.machineOfAthanor("ath_a")
	k.guest.mu.Lock()
	k.guest.refuseBoot = errors.New("the VMM's space did not start")
	k.guest.mu.Unlock()
	k.guard.mu.Lock()
	k.guard.refuseClears = 1
	k.guard.mu.Unlock()
	k.s.handleSpawn(k.c, k.spawnReq("s1", "p-s1", "vlt_a1", nil))
	if got := k.next(t); got["type"] != "error" {
		t.Fatalf("a start whose VM did not start answered %v", got)
	}
	k.guest.mu.Lock()
	k.guest.refuseBoot = nil
	k.guest.mu.Unlock()
	k.s.handleSpawn(k.c, k.spawnReq("s2", "p-s2", "vlt_a2", nil))
	k.expect(t, "spawned")
	k.s.mu.Lock()
	running := m.id
	k.s.mu.Unlock()
	asked := len(k.guard.taken())
	k.s.retryClears()
	for _, c := range k.guard.taken()[asked:] {
		if c.op == guard.TypeClear && c.spawnID == running {
			t.Fatalf("a clear retried for a boot that did not start was asked of the running VM's route %s", running)
		}
	}
	k.s.mu.Lock()
	held := m.route != nil
	k.s.mu.Unlock()
	if !held {
		t.Fatal("a clear retried for a boot that did not start let the running VM's hold on its route go")
	}
}
