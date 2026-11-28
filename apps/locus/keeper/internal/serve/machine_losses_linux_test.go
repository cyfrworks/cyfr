// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package serve

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/cyfr/locus/keeper/guard"
	"github.com/cyfr/locus/keeper/internal/admission"
	"github.com/cyfr/locus/keeper/internal/cgroup"
	"github.com/cyfr/locus/keeper/internal/protocol"
	"github.com/cyfr/locus/keeper/internal/vm"
)

// The losses and the lifetime of a person's VM that no test held before
// (4742 fail 5, breaks R3, R4, R6, R7, R10 and R13): each test fails
// without the behaviour it names.

// idleLongAgo sets m's idle clock an hour back, as a VM at rest that long.
func (k *vmKeeper) idleLongAgo(m *machine) {
	k.s.mu.Lock()
	m.idleSince = now().Add(-time.Hour)
	k.s.mu.Unlock()
}

// The idle clock starts again at a VM's last session's release (R3): a VM
// booted long ago whose one session is released now is not idle past its
// bound.
func TestTheIdleClockStartsAtTheLastSessionsRelease(t *testing.T) {
	idleFor(t, time.Minute)
	k := newVMKeeper(t)
	k.disk(t, "ath_a", "vlt_a1")
	id, _ := k.session(t, "s1", "ath_a", "vlt_a1", nil)
	m := k.machineOfAthanor("ath_a")
	k.idleLongAgo(m)
	ms := int64(0)
	k.s.handle(k.c, &protocol.Request{V: protocol.Version, Type: protocol.TypeRelease, SpawnID: id, GraceMs: &ms})
	k.expect(t, "released")
	k.s.handle(k.c, &protocol.Request{V: protocol.Version, Type: protocol.TypeDrop, Place: "p-s1"})
	k.s.endIdleMachines()
	if f := k.guest.booted()[0]; f.ended() {
		t.Fatal("a VM whose last session was released a moment ago ended as idle past its bound")
	}
}

// A VM a place of its person's names is not ended at rest, neither by the
// idle bound nor for room (R4): the place's start would boot it again.
func TestAVMAPlaceNamesIsNotEndedAtRest(t *testing.T) {
	idleFor(t, time.Minute)
	k := newVMKeeper(t)
	k.disk(t, "ath_a", "vlt_a1", "vlt_a2")
	id, _ := k.session(t, "s1", "ath_a", "vlt_a1", nil)
	ms := int64(0)
	k.s.handle(k.c, &protocol.Request{V: protocol.Version, Type: protocol.TypeRelease, SpawnID: id, GraceMs: &ms})
	k.expect(t, "released")
	k.s.handle(k.c, &protocol.Request{V: protocol.Version, Type: protocol.TypeDrop, Place: "p-s1"})
	k.place(t, "p-s2", "ath_a")
	m := k.machineOfAthanor("ath_a")
	k.idleLongAgo(m)
	k.s.endIdleMachines()
	k.s.giveWay(m)
	if f := k.guest.booted()[0]; f.ended() {
		t.Fatal("a VM a waiting place of its person names was ended at rest")
	}
	k.s.handle(k.c, &protocol.Request{V: protocol.Version, Type: protocol.TypeDrop, Place: "p-s2"})
	k.s.endIdleMachines()
	vmEventually(t, "the VM's end once no place names it", k.guest.booted()[0].ended)
}

// An ended VM's charge is frozen until its release (R6): a VM that ends in
// its first start's allowance time, its clear refused, is still charged
// that start's hold once the time has passed.
func TestAnEndedVMsChargeIsFrozenUntilItsRelease(t *testing.T) {
	k := newVMKeeper(t)
	k.disk(t, "ath_a", "vlt_a1")
	k.session(t, "s1", "ath_a", "vlt_a1", nil)
	m := k.machineOfAthanor("ath_a")
	held := k.usedNow()
	if want := admission.Allowance(admission.Session) + admission.MachineBytes(k.s.machineGuest()); held != want {
		t.Fatalf("a first start holds %d, want %d", held, want)
	}
	k.guard.mu.Lock()
	k.guard.refuseClears = 1
	k.guard.mu.Unlock()
	k.guest.booted()[0].Kill()
	k.expect(t, "released")
	vmEventually(t, "the refused clear's record", func() bool {
		k.s.mu.Lock()
		defer k.s.mu.Unlock()
		_, held := k.s.uncleared[m.id]
		return held
	})
	saved := now
	t.Cleanup(func() { now = saved })
	now = func() time.Time { return saved().Add(admission.AllowanceFor + time.Minute) }
	if got := k.usedNow(); got != held {
		t.Fatalf("an ended VM not yet released is charged %d past its start's allowance time, want its charge at its end, %d", got, held)
	}
}

// A VM's end tells its sessions itself (R7): where its control
// connection's end is not seen, every session in it is still told it ended
// with SIGKILL, and released.
func TestAVMsEndTellsItsSessionsItself(t *testing.T) {
	k := newVMKeeper(t)
	k.disk(t, "ath_a", "vlt_a1")
	k.session(t, "s1", "ath_a", "vlt_a1", nil)
	f := k.guest.booted()[0]
	f.mu.Lock()
	f.keepControls = true
	f.mu.Unlock()
	f.end(vm.EndOwnExit, cgroup.NotKilled)
	m := k.expect(t, "exited")
	if m["signal"] != "SIGKILL" || m["code"] != nil {
		t.Fatalf("a session of an ended VM was told %v", m)
	}
	k.expect(t, "released")
}

// A VM's route admitted as the guard's connection ended is refused (R10):
// its session is refused guard_unavailable, no VM boots, and the route is
// withdrawn.
func TestAVMsRouteAdmittedAsTheGuardsConnectionEndedIsRefused(t *testing.T) {
	k := newVMKeeper(t)
	k.disk(t, "ath_a", "vlt_a1")
	k.guard.mu.Lock()
	k.guard.dead = true
	k.guard.mu.Unlock()
	k.place(t, "p-s1", "ath_a")
	k.s.handleSpawn(k.c, k.spawnReq("s1", "p-s1", "vlt_a1", nil))
	if m := k.next(t); m["type"] != "error" || m["code"] != protocol.CodeGuardUnavailable {
		t.Fatalf("a start whose VM's route came over an ended connection answered %v", m)
	}
	if n := len(k.guest.booted()); n != 0 {
		t.Fatalf("%d VMs booted on a route the guard's ended connection made", n)
	}
	var ops []string
	for _, c := range k.guard.taken() {
		ops = append(ops, c.op)
	}
	if len(ops) < 2 || ops[len(ops)-1] != guard.TypeClear {
		t.Fatalf("the route was not withdrawn: the guard was asked %v", ops)
	}
}

// A VM's group that outlives its kill at the guard's loss ends the keeper
// (R13), before anything dials the guard again.
func TestAVMsGroupThatOutlivesItsKillAtTheGuardsLossEndsTheKeeper(t *testing.T) {
	k := newVMKeeper(t)
	k.disk(t, "ath_a", "vlt_a1")
	k.session(t, "s1", "ath_a", "vlt_a1", nil)
	g, err := k.c.role.groups.Create("vm-left", 0, 0)
	if err != nil {
		t.Fatal(err)
	}
	// A pid no process has (past the kernel's most), which no kill
	// reaches, in the group's folder: its leaf, "bound", under its mark.
	if err := os.WriteFile(filepath.Join(k.c.role.groups.Dir(), "vm-left", "bound", "cgroup.procs"), []byte("4194305\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	f := k.guest.booted()[0]
	f.mu.Lock()
	f.group = g
	f.mu.Unlock()
	exited := make(chan int, 1)
	k.s.exit = func(code int) { exited <- code }
	k.s.guardLost(k.guard.conn)
	select {
	case code := <-exited:
		if code != ExitLost {
			t.Fatalf("the keeper ended %d, want %d", code, ExitLost)
		}
	case <-time.After(20 * time.Second):
		t.Fatal("a VM's group that outlived its kill at the guard's loss left the keeper running")
	}
}
