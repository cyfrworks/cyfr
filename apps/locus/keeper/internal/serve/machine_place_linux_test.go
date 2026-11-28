// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package serve

import (
	"errors"
	"os"
	"slices"
	"testing"
	"time"

	"github.com/cyfr/locus/keeper/internal/admission"
	"github.com/cyfr/locus/keeper/internal/home"
	"github.com/cyfr/locus/keeper/internal/protocol"
)

// A person's VM and the places that name it: a VM no place names is never
// booted, and one whose places went while it booted and failed leaves
// nothing behind, no charge and no VM in no map.

// @Fable3's (4742 fail 4): a measure boots the person's VM for a place of
// theirs, the place is dropped as it boots, and the boot fails.
func TestAPlaceDroppedWhileAMeasureBootsLeavesNothingWhenTheBootFails(t *testing.T) {
	k := newVMKeeper(t)
	k.disk(t, "ath_a", "vlt_a1")
	k.place(t, "p-s1", "ath_a")
	entered, gate := make(chan struct{}), make(chan struct{})
	k.s.bootVM = func(b vmBoot) (guestVM, error) {
		close(entered)
		<-gate
		return nil, errors.New("the VMM's space did not start")
	}
	go k.s.handle(k.c, &protocol.Request{V: protocol.Version, Type: protocol.TypeHomeMeasure, ID: "m1", Home: "vlt_a1"})
	select {
	case <-entered:
	case <-time.After(20 * time.Second):
		t.Fatal("the measure never booted")
	}
	k.s.handle(k.c, &protocol.Request{V: protocol.Version, Type: protocol.TypeDrop, Place: "p-s1"})
	close(gate)
	if m := k.next(t); m["type"] != "error" {
		t.Fatalf("the measure answered %v", m)
	}
	k.s.mu.Lock()
	used := k.s.ledger.Report("backends", 0, now()).Used
	m := k.s.vms["ath_a"]
	k.s.mu.Unlock()
	if used != 0 || m != nil {
		t.Fatalf("with no place and no VM, the pool holds %d MiB for the person's VM, kept %t", used>>20, m != nil)
	}
}

// @Fable3's (4742 fail 4): a measure found the person's VM held by a place,
// and the place's drop came before its boot.
func TestAMeasureBootsNoVMItsPlacesDropLetGo(t *testing.T) {
	idleFor(t, 0)
	k := newVMKeeper(t)
	k.disk(t, "ath_a", "vlt_a1")
	k.place(t, "p-s1", "ath_a")
	k.s.mu.Lock()
	m := k.s.vms["ath_a"]
	held := m != nil && !m.ending && (m.vm != nil || m.entry.Admitted())
	k.s.mu.Unlock()
	if !held {
		t.Fatal("the test's premise: a placed session holds the person's VM's room")
	}
	k.s.handle(k.c, &protocol.Request{V: protocol.Version, Type: protocol.TypeDrop, Place: "p-s1"})
	code := k.s.bootMachine(m, keptAt{athanor: "ath_a", uid: os.Getuid(), image: true}, k.c.role)
	k.s.endIdleMachines()
	k.s.mu.Lock()
	used := k.s.ledger.Report("backends", 0, now()).Used
	known := k.s.vms["ath_a"] != nil
	k.s.mu.Unlock()
	if booted := k.guest.booted(); len(booted) != 0 || code != protocol.CodeUnavailable || known || used != 0 {
		t.Fatalf("a VM whose place was dropped: boot answered %q, %d VMs booted, the keeper knows one %t, the pool holds %d bytes", code, len(booted), known, used)
	}
}

// scratchReq is a spawn of no kept home in place.
func (k *vmKeeper) scratchReq(id, place string) *protocol.Request {
	r := k.spawnReq(id, place, "", nil)
	r.HomeMode, r.Home = "", ""
	return r
}

// A program with no kept folder runs in its person's VM like any other
// session (ruling 1 of 4748). A person whose programs are all scratch has
// no disk: their first session makes its record and its image, as a home's
// first make does, with no home; the VM boots with it, and the guest is
// sent a scratch spawn, with no home made, which its keeper runs in its own
// pool on its own tmpfs.
func TestAScratchSessionRunsInItsPersonsVMOnADiskMadeForIt(t *testing.T) {
	if _, err := os.Stat(home.Mke2fs); err != nil {
		t.Skipf("this host has no %s for the person's image: %v", home.Mke2fs, err)
	}
	k := newVMKeeper(t)
	k.place(t, "p-s1", "ath_a")
	k.s.handleSpawn(k.c, k.scratchReq("s1", "p-s1"))
	if m := k.next(t); m["type"] != "spawned" {
		t.Fatalf("the scratch session answered %v", m)
	}
	d, err := k.kept.ReadDisk("ath_a")
	if err != nil || d.Form != home.FormImage || len(d.Homes) != 0 || d.UID != os.Getuid() {
		t.Fatalf("the person's disk is %+v, %v: want an image of their uid holding no home", d, err)
	}
	if err := home.CheckImage(k.kept.ImagePath("ath_a"), d.UID); err != nil {
		t.Fatalf("the person's image: %v", err)
	}
	booted := k.guest.booted()
	if len(booted) != 1 || booted[0].boot.Disk != k.kept.ImagePath("ath_a") || booted[0].boot.UID != d.UID {
		t.Fatalf("the scratch session's VM: %d booted, %+v", len(booted), booted)
	}
	if got := k.guest.requests(); slices.Contains(got, protocol.TypeHomeMake) {
		t.Fatalf("a scratch session had a home made in its guest: %v", got)
	}
	k.guest.mu.Lock()
	var spawn map[string]any
	for _, r := range k.guest.seen {
		if r["type"] == protocol.TypeSpawn {
			spawn = r
		}
	}
	k.guest.mu.Unlock()
	if spawn == nil || spawn["home_mode"] != nil || spawn["home"] != nil || spawn["pool"] != "backends" {
		t.Fatalf("the guest was sent %v, want a scratch spawn in its pool", spawn)
	}
}

// A scratch session of a person whose kept session runs joins their VM:
// no second VM, both sessions in the one.
func TestAScratchSessionsPlaceNeedsNoSecondVM(t *testing.T) {
	k := newVMKeeper(t)
	k.disk(t, "ath_a", "vlt_a1")
	k.session(t, "s1", "ath_a", "vlt_a1", nil)
	k.place(t, "p-s2", "ath_a")
	k.s.handleSpawn(k.c, k.scratchReq("s2", "p-s2"))
	if m := k.next(t); m["type"] != "spawned" {
		t.Fatalf("the scratch session answered %v", m)
	}
	m := k.machineOfAthanor("ath_a")
	if n := len(k.guest.booted()); n != 1 || sessionsOf(k, m) != 2 {
		t.Fatalf("a scratch session beside a kept one: %d VMs, %d sessions in the person's", n, sessionsOf(k, m))
	}
	k.s.mu.Lock()
	used := k.s.ledger.Report("backends", 0, now()).Used
	k.s.mu.Unlock()
	if want := admission.Allowance(admission.Session)*2 + admission.MachineBytes(k.s.machineGuest()); used != want {
		t.Fatalf("the pool holds %d with the two starts under way in one VM, want %d: the VM's own once", used, want)
	}
}

// A scratch program's place is a start in its person's VM, so it needs the
// VM's own room beside its allowance where the VM is not yet admitted; the
// reviewer's test (4742 fail 1), inverted by ruling 1's shape (a): a pool
// of two sessions' allowances holds no start that boots a VM.
func TestAPlaceOfAScratchSessionNeedsItsVMsRoom(t *testing.T) {
	k := newVMKeeper(t)
	k.s.ledger = admission.New(2*admission.Allowance(admission.Session), false)
	k.s.handle(k.c, &protocol.Request{V: protocol.Version, Type: protocol.TypePlace, ID: "p1", Kind: "program", Athanor: "ath_a", Subject: "mcp_scratch"})
	m := k.next(t)
	held, _ := m["held"].(map[string]any)
	if m["type"] != "error" || m["code"] != protocol.CodeNoMemory || held == nil ||
		uint64(held["need"].(float64)) != admission.Allowance(admission.Session)+admission.MachineBytes(k.s.machineGuest()) {
		t.Fatalf("a scratch program's place in a pool too small for its VM answered %v", m)
	}
}
