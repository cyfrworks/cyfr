// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package admission

import (
	"slices"
	"testing"
)

// inVM is a session of athanor's placed in its VM m.
func inVM(m *Entry, subject string) *Entry {
	e := session(m.Athanor, subject)
	e.Machine = m
	return e
}

func used(l *Ledger, s float64) uint64 { return l.used(l.inFloor(), at(s)) }

// A person's first session boots their VM: its start reserves its own
// allowance and the VM's beside it, and from the VMM's start the host is
// charged the VM's reading, never under what its starts hold, and never
// the session's own reading on top of it.
func TestAFirstSessionInAVMReservesItsAllowanceAndTheVMsOwn(t *testing.T) {
	work := uint64(4096 * mib)
	l := New(work, false)
	m := NewMachine("backends", "ath_a", nil)
	a := inVM(m, "p1")
	if ev := l.Place(a, at(0)); !slices.Equal(ev.Admitted, []*Entry{a}) {
		t.Fatalf("admitted %v, want the session alone: a VM is never answered placed", ev.Admitted)
	}
	if !m.Admitted() {
		t.Fatal("the VM was not admitted with its first session")
	}
	if got, want := used(l, 0), uint64((384+326)*mib); got != want {
		t.Fatalf("a booting VM's first start holds %d, want %d", got, want)
	}
	// The VMM starts at 1 s and reads 200 MiB; the session spawns at 2 s
	// and its guest reading is 90 MiB, which is under the VM's and never
	// added to it.
	l.Spawned(m, at(1))
	l.Read(m, 200*mib, false, at(1))
	l.Spawned(a, at(2))
	l.Read(a, 90*mib, false, at(2))
	if got, want := used(l, 5), uint64((384+326)*mib); got != want {
		t.Fatalf("during both allowances' time the VM holds %d, want %d", got, want)
	}
	// Past the VM's own allowance (11 s) only the session's is held.
	l.Read(m, 300*mib, false, at(11.5))
	if got, want := used(l, 11.5), uint64(384*mib); got != want {
		t.Fatalf("past the VM's own allowance it holds %d, want the session's %d", got, want)
	}
	// Past the session's (12 s): the VM's reading alone.
	l.Read(m, 450*mib, false, at(12.5))
	if got, want := used(l, 12.5), uint64(450*mib); got != want {
		t.Fatalf("past every allowance the host is charged %d, want the VM's reading %d", got, want)
	}
	if got := l.charge(a, at(12.5)); got != 0 {
		t.Fatalf("a session in a VM is charged %d of its own", got)
	}
	if r := l.Report("backends", 0, at(12.5)); r.Used != 450*mib {
		t.Fatalf("the report's used %d, want the VM's reading", r.Used)
	} else {
		var counted uint64
		for _, c := range r.Counters {
			if c.Subject != "p1" {
				t.Fatalf("a counter %+v is not the session's: the VM's own charge is in none", c)
			}
			counted += c.Bytes
		}
		if counted != 90*mib || counted > r.Used {
			t.Fatalf("the counters hold %d, want the session's guest reading %d, no more than used", counted, 90*mib)
		}
	}
}

// A second session joins the running VM: its start holds the VM's reading
// at its admission and its allowance, never the VM's own again.
func TestASecondSessionJoinsItsVMsCharge(t *testing.T) {
	l := New(4096*mib, false)
	m := NewMachine("backends", "ath_a", nil)
	a := inVM(m, "p1")
	spawned(t, l, a, 0, 80*mib)
	l.Spawned(m, at(0))
	l.Read(m, 500*mib, false, at(20))
	b := inVM(m, "p2")
	if got := b.startNeed(); got != 384*mib {
		t.Fatalf("a start in a running VM needs %d, want a session's allowance alone", got)
	}
	admitted(t, l.Place(b, at(20)), b)
	if got, want := used(l, 21), uint64((500+384)*mib); got != want {
		t.Fatalf("the VM with a session starting holds %d, want its reading at the admission and the allowance %d", got, want)
	}
	l.Spawned(b, at(21))
	l.Read(m, 620*mib, false, at(32))
	if got, want := used(l, 32), uint64(620*mib); got != want {
		t.Fatalf("once the start's time passed the VM holds %d, want its reading %d", got, want)
	}
}

// The VM's charge counts toward its person's ceiling: a person at their
// ceiling is refused a start in their VM as they would be on the host.
func TestAPersonAtTheirCeilingIsRefusedAStartInTheirVM(t *testing.T) {
	l := New(8192*mib, false)
	m := NewMachine("backends", "ath_a", nil)
	a := inVM(m, "p1")
	a.AthanorMax = 1200 * mib
	spawned(t, l, a, 0, 100*mib)
	l.Spawned(m, at(0))
	l.Read(m, 900*mib, false, at(15))
	b := inVM(m, "p2")
	b.AthanorMax = 1200 * mib
	if ev := l.Place(b, at(15)); len(ev.Admitted) != 0 || len(ev.Refused) != 0 {
		t.Fatalf("a start over its person's ceiling was settled at once: %+v", ev)
	}
	ev := l.Tick(at(15 + RoomWait.Seconds()))
	if len(ev.Refused) != 1 || ev.Refused[0].Entry != b {
		t.Fatalf("a start held by its person's ceiling was not refused at its wait's end: %+v", ev)
	}
	// On the host the same person with the same charge is refused alike.
	h := New(8192*mib, false)
	ha := session("ath_a", "p1")
	ha.AthanorMax = 1200 * mib
	spawned(t, h, ha, 0, 900*mib)
	hb := session("ath_a", "p2")
	hb.AthanorMax = 1200 * mib
	h.Place(hb, at(15))
	if ev := h.Tick(at(15 + RoomWait.Seconds())); len(ev.Refused) != 1 {
		t.Fatalf("on the host the start is not refused alike: %+v", ev)
	}
}

// A VM that holds no session is idle work: at a full pool it is asked to
// give way, beside kept runners, oldest at rest first, before any start is
// refused; a VM that holds a session, or one a waiting start needs, is not.
func TestAnIdleVMGivesWayToAStartAtAFullPool(t *testing.T) {
	l := New(2048*mib, false)
	m := NewMachine("backends", "ath_a", "vm-a")
	a := inVM(m, "p1")
	spawned(t, l, a, 0, 100*mib)
	l.Spawned(m, at(0))
	l.Read(m, 1700*mib, false, at(20))
	// While its session lives it is not asked.
	other := session("ath_b", "q1")
	if ev := l.Place(other, at(20)); len(ev.GiveWay) != 0 || len(ev.Admitted) != 0 {
		t.Fatalf("a VM with a session was asked to give way, or the start fit: %+v", ev)
	}
	l.Drop(other, at(20))
	l.Drop(a, at(21))
	if l.Sessions(m) != 0 {
		t.Fatal("the VM still holds a session")
	}
	// A start of its own person needs it: it is not asked.
	own := inVM(m, "p2")
	if ev := l.Place(own, at(22)); len(ev.GiveWay) != 0 {
		t.Fatalf("the VM a waiting start needs was asked to give way: %+v", ev)
	}
	l.Drop(own, at(22))
	// Another person's start: the idle VM is asked, and once it is gone
	// the start is admitted.
	b := session("ath_b", "q2")
	ev := l.Place(b, at(23))
	if !slices.Equal(ev.GiveWay, []*Entry{m}) {
		t.Fatalf("asked %v to give way, want the idle VM", ev.GiveWay)
	}
	l.Ending(m, at(24))
	admitted(t, l.Drop(m, at(25)), b)
	if got, want := free(l, 25), uint64((2048-384)*mib); got != want {
		t.Fatalf("after the VM's release %d is free, want %d", got, want)
	}
}

// A refusal's account holds a person's VM through their sessions: each
// session's holding is its reading and its share of the VM's own, and the
// person's holdings together are the VM's charge, none of it another's.
func TestARefusalCountsAPersonsVMAsTheirsThroughTheirSessions(t *testing.T) {
	l := New(2048*mib, false)
	m := NewMachine("backends", "ath_a", nil)
	a, b := inVM(m, "p1"), inVM(m, "p2")
	spawned(t, l, a, 0, 100*mib)
	spawned(t, l, b, 0, 50*mib)
	l.Spawned(m, at(0))
	l.Read(m, 1700*mib, false, at(20))
	c := inVM(m, "p3")
	l.Place(c, at(20))
	ev := l.Tick(at(20 + RoomWait.Seconds()))
	if len(ev.Refused) != 1 {
		t.Fatalf("the start was not refused: %+v", ev)
	}
	h := ev.Refused[0].Held
	var mine uint64
	for _, k := range h.Mine {
		mine += k.Bytes
	}
	if mine != 1700*mib || h.Others != 0 {
		t.Fatalf("the person holds %d and others %d, want the VM's charge %d as theirs: %+v", mine, h.Others, 1700*mib, h.Mine)
	}
	if h.Mine[0].Bytes <= h.Mine[1].Bytes {
		t.Fatalf("the larger session holds no more than the smaller: %+v", h.Mine)
	}
}

// A session placed in a VM whose spawn runs on the host after all is
// charged by itself from then on, and leaves the VM at rest.
func TestADetachedSessionIsChargedByItself(t *testing.T) {
	l := New(4096*mib, false)
	m := NewMachine("backends", "ath_a", nil)
	a := inVM(m, "p1")
	admitted(t, l.Place(a, at(0)), a)
	l.Detach(a, at(1))
	if a.Machine != nil || l.Sessions(m) != 0 {
		t.Fatal("the session is still the VM's")
	}
	if got := l.charge(a, at(1)); got != 384*mib {
		t.Fatalf("the detached session is charged %d, want its allowance", got)
	}
}
