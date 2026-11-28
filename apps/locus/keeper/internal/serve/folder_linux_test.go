// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package serve

import (
	"os"
	"slices"
	"testing"
	"time"

	"github.com/cyfr/locus/keeper/internal/admission"
	"github.com/cyfr/locus/keeper/internal/logx"
	"github.com/cyfr/locus/keeper/internal/protocol"
)

// homeOp asks k's keeper the operation typ of home and answers its reply.
func (k *vmKeeper) homeOp(t *testing.T, typ, id, home string) map[string]any {
	t.Helper()
	k.s.handle(k.c, &protocol.Request{V: protocol.Version, Type: typ, ID: id, Home: home})
	return k.next(t)
}

// recorded says whether k's keeper's record of athanor's disk holds home.
func (k *vmKeeper) recorded(athanor, home string) bool {
	k.s.mu.Lock()
	defer k.s.mu.Unlock()
	d := k.s.disks[athanor]
	return d != nil && d.Holds(home)
}

// A folder's reset or retirement on an image, with no VM of its person's
// running, boots their VM for it, which the log names as such: the guest's
// keeper resets or retires the home, a retired home leaves the disk's
// record, and the VM is then an ordinary idle VM, which a second operation
// finds standing and the idle bound ends.
func TestAFoldersOperationBootsItsPersonsVMAndLeavesItIdle(t *testing.T) {
	k := newVMKeeper(t)
	log := &lockedLog{}
	k.s.log = logx.NewWriter(log, "cyfr-locus", false)
	k.disk(t, "ath_a", "vlt_a1", "vlt_a2")
	if m := k.homeOp(t, protocol.TypeHomeReset, "r1", "vlt_a1"); m["type"] != "home_made" || m["uid"] != float64(os.Getuid()) {
		t.Fatalf("a folder's reset answered %v", m)
	}
	if n := len(k.guest.booted()); n != 1 {
		t.Fatalf("the reset booted %d VMs, want its person's one", n)
	}
	if got := log.lines("booted for a folder's reset"); len(got) != 1 {
		t.Fatalf("the keeper's log says of the boot %q", log.lines("booted"))
	}
	m := k.machineOfAthanor("ath_a")
	k.s.mu.Lock()
	standing, admitted, held := m != nil && m.vm != nil, m != nil && m.entry.Admitted(), m.places
	k.s.mu.Unlock()
	if !standing || !admitted || held != 0 {
		t.Fatalf("after the reset the VM stands %t, admitted %t, held by %d", standing, admitted, held)
	}
	if !slices.Contains(k.guest.requests(), protocol.TypeHomeReset) {
		t.Fatalf("the guest read %v, no reset", k.guest.requests())
	}
	if m := k.homeOp(t, protocol.TypeHomeRetire, "r2", "vlt_a2"); m["type"] != "home_retired" {
		t.Fatalf("a folder's retirement answered %v", m)
	}
	if n := len(k.guest.booted()); n != 1 {
		t.Fatalf("the retirement booted %d VMs, want the standing one alone", n)
	}
	if k.recorded("ath_a", "vlt_a2") || !k.recorded("ath_a", "vlt_a1") {
		t.Fatalf("the disk's record holds vlt_a1 %t and vlt_a2 %t after vlt_a2's retirement", k.recorded("ath_a", "vlt_a1"), k.recorded("ath_a", "vlt_a2"))
	}
	idleFor(t, 0)
	k.s.endIdleMachines()
	vmEventually(t, "the idle VM's end", k.guest.booted()[0].ended)
}

// A folder's operation whose person's VM finds no room in the pool is
// refused as no room, and changes nothing: no VM boots, the disk's record
// stands, and no VM of the person's is left held.
func TestAFoldersOperationWithNoRoomChangesNothing(t *testing.T) {
	k := newVMKeeper(t)
	k.s.ledger = admission.New(admission.MachineBytes(k.s.machineGuest())-1, false)
	k.disk(t, "ath_a", "vlt_a1")
	if m := k.homeOp(t, protocol.TypeHomeRetire, "r1", "vlt_a1"); m["type"] != "error" || m["code"] != protocol.CodeCapacity {
		t.Fatalf("a retirement with no room for its VM answered %v", m)
	}
	if n := len(k.guest.booted()); n != 0 || !k.recorded("ath_a", "vlt_a1") || k.machineOfAthanor("ath_a") != nil {
		t.Fatalf("a refused retirement booted %d VMs, kept the record %t, left a VM %v", n, k.recorded("ath_a", "vlt_a1"), k.machineOfAthanor("ath_a"))
	}
}

// The sessions of a folder in its person's VM end before its reset, as on
// the host: the guest is asked their release first, and the keeper says
// they ended before it answers the reset. Another folder's session runs on.
func TestAFoldersSessionsInTheVMEndBeforeItsReset(t *testing.T) {
	k := newVMKeeper(t)
	k.disk(t, "ath_a", "vlt_a1", "vlt_a2")
	k.session(t, "s1", "ath_a", "vlt_a1", nil)
	s2, _ := k.session(t, "s2", "ath_a", "vlt_a2", nil)
	k.s.handle(k.c, &protocol.Request{V: protocol.Version, Type: protocol.TypeHomeReset, ID: "r1", Home: "vlt_a1"})
	var seen []string
	for {
		m := k.next(t)
		seen = append(seen, m["type"].(string))
		if m["type"] == "home_made" || m["type"] == "error" {
			break
		}
	}
	if i := slices.Index(seen, "exited"); i < 0 || seen[len(seen)-1] != "home_made" {
		t.Fatalf("the keeper said %v, want the session's end before the reset's answer", seen)
	}
	asked := k.guest.requests()
	if r, h := slices.Index(asked, protocol.TypeRelease), slices.Index(asked, protocol.TypeHomeReset); r < 0 || h < r {
		t.Fatalf("the guest read %v, want the session's release before the reset", asked)
	}
	m := k.machineOfAthanor("ath_a")
	k.s.mu.Lock()
	_, runs := m.sessions[s2]
	k.s.mu.Unlock()
	if !runs {
		t.Fatal("another folder's session ended with the reset")
	}
}

// A folder's operation over a guest of another boot than the one the
// keeper greeted settles nothing: it is refused, the disk's record stands,
// and the VM, in no known state, ends.
func TestAFoldersOperationOverAGuestOfAnotherBootSettlesNothing(t *testing.T) {
	saved := vmEndWait
	vmEndWait = 10 * time.Millisecond
	t.Cleanup(func() { vmEndWait = saved })
	k := newVMKeeper(t)
	k.disk(t, "ath_a", "vlt_a1", "vlt_a2")
	k.session(t, "s1", "ath_a", "vlt_a1", nil)
	f := k.guest.booted()[0]
	f.mu.Lock()
	f.bootID = "99999999-4b5a-4978-8796-a5b4c3d2e1f0"
	control := f.controls[0]
	f.mu.Unlock()
	_ = control.Close()
	k.expect(t, "released")
	if m := k.homeOp(t, protocol.TypeHomeRetire, "r1", "vlt_a2"); m["type"] != "error" {
		t.Fatalf("a retirement over a guest of another boot answered %v", m)
	}
	if !k.recorded("ath_a", "vlt_a2") || slices.Contains(k.guest.requests(), protocol.TypeHomeRetire) {
		t.Fatalf("a retirement over a guest of another boot kept the record %t, reached the guest %t",
			k.recorded("ath_a", "vlt_a2"), slices.Contains(k.guest.requests(), protocol.TypeHomeRetire))
	}
	vmEventually(t, "the VM's end", f.ended)
}

// A folder's operation whose person's VM finds the pool full waits for
// room as a start waits, and goes on once a place leaves.
func TestAFoldersOperationWaitsForItsVMsRoom(t *testing.T) {
	k := newVMKeeper(t)
	own := admission.MachineBytes(k.s.machineGuest())
	k.s.ledger = admission.New(own+383<<20, false)
	k.disk(t, "ath_a", "vlt_a1")
	held := &admission.Entry{Role: "backends", Kind: "program", Athanor: "ath_b", Subject: "mcp_b", Ref: placeRef{c: k.c, id: "pb"}}
	k.s.mu.Lock()
	k.s.admit(k.s.ledger.Place(held, now()))
	k.s.mu.Unlock()
	if m := k.next(t); m["type"] != "placed" {
		t.Fatalf("the place that fills the pool answered %v", m)
	}
	go k.s.handle(k.c, &protocol.Request{V: protocol.Version, Type: protocol.TypeHomeReset, ID: "r1", Home: "vlt_a1"})
	vmEventually(t, "the VM's wait for room", func() bool {
		m := k.machineOfAthanor("ath_a")
		k.s.mu.Lock()
		defer k.s.mu.Unlock()
		return m != nil && m.alone != nil
	})
	if n := len(k.guest.booted()); n != 0 {
		t.Fatalf("%d VMs booted with no room for one", n)
	}
	k.s.mu.Lock()
	k.s.admit(k.s.ledger.Drop(held, now()))
	k.s.mu.Unlock()
	if m := k.next(t); m["type"] != "home_made" {
		t.Fatalf("the reset answered %v once room came", m)
	}
}
