// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package serve

import (
	"errors"
	"os"
	"testing"
	"time"

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
