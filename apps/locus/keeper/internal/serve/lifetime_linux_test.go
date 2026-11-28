// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package serve

import (
	"testing"
	"time"

	"github.com/cyfr/locus/keeper/internal/admission"
	"github.com/cyfr/locus/keeper/internal/protocol"
	"github.com/cyfr/locus/keeper/internal/vm"
)

// idleFor shortens the idle bound for one test.
func idleFor(t *testing.T, d time.Duration) {
	saved := machineIdleFor
	machineIdleFor = d
	t.Cleanup(func() { machineIdleFor = saved })
}

// usedNow is what the pool holds now, as the report says it.
func (k *vmKeeper) usedNow() uint64 {
	k.s.mu.Lock()
	defer k.s.mu.Unlock()
	return k.s.ledger.Report("backends", 0, now()).Used
}

// A person's VM outlives their last session: a turn that starts after it
// joins the same VM, its boot identity unchanged. It ends once it has held
// no session for the idle bound, asked of its guest within the close's
// bound, and is released: the pool holds nothing of it after.
func TestAVMThatHeldNoSessionForTheIdleBoundEnds(t *testing.T) {
	idleFor(t, time.Hour)
	k := newVMKeeper(t)
	k.disk(t, "ath_a", "vlt_a1")
	id, _ := k.session(t, "s1", "ath_a", "vlt_a1", nil)
	ms := int64(0)
	k.s.handle(k.c, &protocol.Request{V: protocol.Version, Type: protocol.TypeRelease, SpawnID: id, GraceMs: &ms})
	k.expect(t, "released")
	m := k.machineOfAthanor("ath_a")
	k.s.endIdleMachines()
	f := k.guest.booted()[0]
	if f.ended() {
		t.Fatal("a VM within its idle bound ended")
	}
	again, _ := k.session(t, "s2", "ath_a", "vlt_a1", nil)
	if len(k.guest.booted()) != 1 || k.machineOfAthanor("ath_a") != m {
		t.Fatal("a turn after the last session ended did not join the same VM")
	}
	// Past its bound while a session lives, it stays.
	machineIdleFor = 0
	k.s.endIdleMachines()
	if f.ended() {
		t.Fatal("a VM holding a session ended at its idle bound")
	}
	k.s.handle(k.c, &protocol.Request{V: protocol.Version, Type: protocol.TypeRelease, SpawnID: again, GraceMs: &ms})
	k.expect(t, "released")
	k.s.endIdleMachines()
	vmEventually(t, "the idle VM's end", f.ended)
	select {
	case <-m.done:
	case <-time.After(20 * time.Second):
		t.Fatal("the idle VM was not released")
	}
	f.mu.Lock()
	asked, how := f.asked, f.how
	f.mu.Unlock()
	if asked != machineCloseWait || how != vm.EndAcknowledged {
		t.Fatalf("the idle VM's end was asked within %s and ended %s, want the close's bound and acknowledged", asked, how)
	}
	if used := k.usedNow(); used != 0 {
		t.Fatalf("the pool holds %d after the idle VM's release", used)
	}
}

// A VM that holds no session gives way to another person's start at a full
// pool, which is admitted once its room is free; one whose end is not
// acknowledged is killed, and released all the same.
func TestAnIdleVMGivesWayToAStartAtAFullPool(t *testing.T) {
	idleFor(t, time.Hour)
	for _, unacked := range []bool{false, true} {
		k := newVMKeeper(t)
		k.s.ledger = admission.New(2048<<20, false)
		k.disk(t, "ath_a", "vlt_a1")
		k.disk(t, "ath_b", "vlt_b1")
		id, _ := k.session(t, "s1", "ath_a", "vlt_a1", nil)
		f := k.guest.booted()[0]
		f.mu.Lock()
		f.used, f.unacked = 1800<<20, unacked
		f.mu.Unlock()
		ms := int64(0)
		k.s.handle(k.c, &protocol.Request{V: protocol.Version, Type: protocol.TypeRelease, SpawnID: id, GraceMs: &ms})
		k.expect(t, "released")
		// The VM's reading holds the pool past its allowances' time.
		k.s.read()()
		k.s.mu.Lock()
		k.s.ledger.Spawned(k.s.vms["ath_a"].entry, now().Add(-time.Minute))
		k.s.mu.Unlock()
		k.s.read()()
		k.s.handle(k.c, &protocol.Request{V: protocol.Version, Type: protocol.TypePlace, ID: "p-b", Kind: "program", Athanor: "ath_b", Subject: "mcp_b"})
		vmEventually(t, "the idle VM's end", f.ended)
		if m := k.next(t); m["type"] != "placed" || m["id"] != "p-b" {
			t.Fatalf("unacked %t: the start the idle VM gave way to answered %v", unacked, m)
		}
		if f.HowEnded() == vm.EndKilled != unacked {
			t.Fatalf("unacked %t: the VM ended %s", unacked, f.HowEnded())
		}
	}
}
