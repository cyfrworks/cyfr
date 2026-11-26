// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package admission

import (
	"reflect"
	"slices"
	"testing"
	"time"
)

// A scripted clock: every step of the ledger is given its now, so each
// case below runs its seconds without waiting for any.
var t0 = time.Date(2026, 11, 26, 12, 0, 0, 0, time.UTC)

func at(s float64) time.Time { return t0.Add(time.Duration(s * float64(time.Second))) }

func runner(role string) *Entry { return &Entry{Role: role, Floor: true, Kind: "warm"} }

func session(athanor, subject string) *Entry {
	return &Entry{Role: "backends", Kind: "program", Athanor: athanor, Subject: subject}
}

func build(athanor string) *Entry { return &Entry{Role: "builds", Kind: "build", Athanor: athanor} }

// admitted says the step admitted exactly these, in order.
func admitted(t *testing.T, ev Events, want ...*Entry) {
	t.Helper()
	if !slices.Equal(ev.Admitted, want) {
		t.Fatalf("admitted %v, want %v", ev.Admitted, want)
	}
}

// spawned places e at s seconds, spawns it at once and reads it at bytes.
func spawned(t *testing.T, l *Ledger, e *Entry, s float64, bytes uint64) {
	t.Helper()
	admitted(t, l.Place(e, at(s)), e)
	l.Spawned(e, at(s))
	l.Read(e, bytes, false, at(s))
}

func free(l *Ledger, s float64) uint64 { return l.free(l.inFloor(), at(s)) }

// Caps are no part of room: two sessions and a build whose caps together
// pass W are admitted, each by its allowance.
func TestCapsOverWAreAdmitted(t *testing.T) {
	work := uint64(2048 * mib)
	l := New(work, false)
	a, b, c := session("ath_a", "p1"), session("ath_a", "p2"), build("ath_b")
	for _, e := range []*Entry{a, b, c} {
		admitted(t, l.Place(e, at(0)), e)
	}
	caps := LimitsOf("program", work).MemoryBytes*2 + LimitsOf("build", work).MemoryBytes
	if caps <= work {
		t.Fatalf("the caps %d do not pass W %d", caps, work)
	}
	if got, want := free(l, 0), work-(384+384+800)*mib; got != want {
		t.Fatalf("free %d, want %d", got, want)
	}
}

// Starts placed in the same second are each charged their allowance before
// any reading, so a third that the readings alone would hold is not.
func TestColdStartsAreEachCounted(t *testing.T) {
	l := New(1000*mib, false)
	a, b, c := session("ath_a", "p1"), session("ath_a", "p2"), session("ath_a", "p3")
	admitted(t, l.Place(a, at(0)), a)
	admitted(t, l.Place(b, at(0)), b)
	if ev := l.Place(c, at(0)); len(ev.Admitted) != 0 || len(ev.Refused) != 0 {
		t.Fatalf("a third start beside two cold ones: %+v", ev)
	}
}

// A lesser reading is never charged under the allowance, and a place with
// no reading for three seconds never under its last charge: neither frees
// room.
func TestLesserAndUnknownReadingsFreeNothing(t *testing.T) {
	l := New(4096*mib, false)
	a, b := session("ath_a", "p1"), session("ath_a", "p2")
	spawned(t, l, a, 0, 10*mib)
	spawned(t, l, b, 0, 10*mib)
	// Past its window, a's lesser reading of 10 MiB is still charged its
	// allowance.
	l.Read(a, 10*mib, true, at(12))
	if got := l.charge(a, at(12)); got != Allowance(Session) {
		t.Fatalf("a lesser reading of 10 MiB is charged %d", got)
	}
	// b was last read at its start, charged its allowance then: unread
	// since, its 10 MiB is no charge, the last one stands.
	if got := l.charge(b, at(12)); got != Allowance(Session) {
		t.Fatalf("b unread since its start is charged %d", got)
	}
	l.Read(b, 100*mib, false, at(13))
	if got := l.charge(b, at(13)); got != 100*mib {
		t.Fatalf("b read again at 100 MiB is charged %d", got)
	}
	if got := l.charge(b, at(15.9)); got != 100*mib {
		t.Fatalf("b unread for 2.9 seconds is charged %d", got)
	}
	// Unread for three seconds since a reading of 100 MiB, it is charged no
	// less than its allowance.
	if got := l.charge(b, at(16)); got != Allowance(Session) {
		t.Fatalf("b unread for three seconds since 100 MiB is charged %d", got)
	}
}

// A runner is charged 164 MiB for its first ten seconds, then its reading.
func TestARunnerIsChargedItsAllowanceThenItsReading(t *testing.T) {
	l := New(4096*mib, true)
	floor, r := runner("runtime"), runner("runtime")
	spawned(t, l, floor, 0, 100*mib)
	spawned(t, l, r, 0, 100*mib)
	l.Assign(r, "run", "ath_a", "", at(1))
	for _, c := range []struct {
		s    float64
		want uint64
	}{{1, 164 * mib}, {9.9, 164 * mib}, {10, 100 * mib}} {
		l.Read(r, 100*mib, false, at(c.s))
		if got := l.charge(r, at(c.s)); got != c.want {
			t.Errorf("at %vs: charged %d, want %d", c.s, got, c.want)
		}
	}
}

// F is kept apart: the floor's runner charges nothing outside it, whatever
// it reads, and with none F is still held.
func TestTheFloorIsKeptApart(t *testing.T) {
	l := New(1024*mib, true)
	if got := free(l, 0); got != (1024-164)*mib {
		t.Fatalf("an empty pool frees %d", got)
	}
	floor := runner("runtime")
	spawned(t, l, floor, 0, 150*mib)
	if got := free(l, 20); got != (1024-164)*mib {
		t.Fatalf("with the floor's runner %d is free", got)
	}
}

// The floor is kept through an assign: the runner given work leaves it and
// is charged by itself, and a fresh runner fills it again at once, needing
// nothing but F.
func TestTheFloorIsKeptThroughAnAssign(t *testing.T) {
	l := New(1024*mib, true)
	floor := runner("runtime")
	spawned(t, l, floor, 0, 120*mib)
	l.Assign(floor, "run", "ath_a", "", at(20))
	l.Read(floor, 140*mib, false, at(20))
	if got := free(l, 20); got != (1024-164-140)*mib {
		t.Fatalf("with the floor's runner given work %d is free", got)
	}
	next := runner("runtime")
	admitted(t, l.Place(next, at(20)), next)
	if got := free(l, 20); got != (1024-164-140)*mib {
		t.Fatalf("with the floor filled again %d is free", got)
	}
}

// Starts are admitted in arrival order: a small one does not pass a large
// one waiting before it.
func TestStartsAreAdmittedInArrivalOrder(t *testing.T) {
	l := New(1500*mib, false)
	a := session("ath_a", "p1")
	spawned(t, l, a, 0, 800*mib)
	b, c := build("ath_b"), session("ath_c", "p2")
	if ev := l.Place(b, at(1)); len(ev.Admitted) != 0 {
		t.Fatalf("the build fits beside 800 MiB held: %+v", ev)
	}
	if ev := l.Place(c, at(1)); len(ev.Admitted) != 0 {
		t.Fatalf("a session passed the build waiting before it: %+v", ev)
	}
	admitted(t, l.Drop(a, at(2)), b, c)
}

// A start that waits asks idle runners to give way before it is refused:
// kept ones oldest first, then fresh ones above the floor, never the
// floor's and never a busy one, and the start is admitted once they are
// gone.
func TestIdleGivesWayBeforeARefusal(t *testing.T) {
	l := New(1300*mib, true)
	floor, fresh, old, young, busy := runner("runtime"), runner("runtime"), runner("runtime"), runner("runtime"), runner("runtime")
	for i, e := range []*Entry{floor, fresh, old, young, busy} {
		spawned(t, l, e, float64(i)*0.1, 130*mib)
	}
	l.Assign(young, "warm", "ath_a", "", at(30))
	l.Assign(old, "warm", "ath_b", "", at(20))
	l.Assign(busy, "run", "ath_c", "", at(25))
	for _, e := range []*Entry{fresh, old, young, busy} {
		l.Read(e, 130*mib, false, at(30))
	}
	// W 1,300, F 164: four runners of 130 hold 520, 616 free; a build
	// needs 800, 184 short: two runners of 130.
	b := build("ath_d")
	ev := l.Place(b, at(30))
	if len(ev.Admitted) != 0 || !slices.Equal(ev.GiveWay, []*Entry{old, young}) {
		t.Fatalf("asked %v, admitted %v; want the two kept ones, oldest first", ev.GiveWay, ev.Admitted)
	}
	// An ask covers what is short only in its own tick: the next second
	// asks the two still standing again, and no one else.
	if ev := l.Tick(at(31)); !slices.Equal(ev.GiveWay, []*Entry{old, young}) {
		t.Fatalf("asked at the next second %v", ev.GiveWay)
	}
	l.Drop(old, at(31.5))
	admitted(t, l.Drop(young, at(31.6)), b)
}

// A start short by more than one runner's charge is served without waiting
// a second for each: every runner that covers it is asked at once.
func TestEveryRunnerThatCoversAShortfallIsAskedAtOnce(t *testing.T) {
	l := New(1200*mib, true)
	floor := runner("runtime")
	spawned(t, l, floor, 0, 100*mib)
	var kept []*Entry
	for i := range 5 {
		e := runner("runtime")
		spawned(t, l, e, 0, 134*mib)
		l.Assign(e, "warm", "ath_a", "", at(float64(20+i)))
		l.Read(e, 134*mib, false, at(30))
		kept = append(kept, e)
	}
	// 1,036 for work, 670 held, 366 free; a build needs 800, 434 short:
	// four runners of 134.
	b := build("ath_b")
	ev := l.Place(b, at(30))
	if !slices.Equal(ev.GiveWay, kept[:4]) {
		t.Fatalf("asked %v at once, want the four oldest", ev.GiveWay)
	}
	for _, e := range kept[:3] {
		l.Drop(e, at(30.1))
	}
	admitted(t, l.Drop(kept[3], at(30.2)), b)
}

// A start that finds no room within 17 seconds is refused with what holds
// the memory; one in a pool of no work is refused at once.
func TestAStartIsRefusedAfterSeventeenSeconds(t *testing.T) {
	l := New(1000*mib, false)
	a := session("ath_a", "p1")
	spawned(t, l, a, 0, 700*mib)
	b := session("ath_a", "p2")
	l.Place(b, at(20))
	if ev := l.Tick(at(36.9)); len(ev.Refused) != 0 {
		t.Fatalf("refused before 17 s: %+v", ev.Refused)
	}
	ev := l.Tick(at(37))
	want := []Refusal{{Entry: b, Held: Held{Need: 384 * mib, Free: 300 * mib,
		Mine: []Holding{{Kind: "program", Subject: "p1", Bytes: 700 * mib}}}}}
	if !reflect.DeepEqual(ev.Refused, want) {
		t.Fatalf("refused %+v, want %+v", ev.Refused, want)
	}
	if ev := l.Tick(at(40)); len(ev.Refused) != 0 || len(ev.Admitted) != 0 {
		t.Fatalf("a refused start is still in the ledger: %+v", ev)
	}
}

func TestZeroWorkRefusesAtOnce(t *testing.T) {
	for name, l := range map[string]*Ledger{"no work": New(0, true), "less than F": New(100*mib, true)} {
		for _, e := range []*Entry{runner("runtime"), build("ath_a"), session("ath_a", "p1")} {
			ev := l.Place(e, at(0))
			if len(ev.Refused) != 1 || ev.Refused[0].Entry != e || len(ev.Admitted) != 0 {
				t.Errorf("%s: a %s place: %+v", name, e.Kind, ev)
			}
		}
	}
}

// A start's refusal names its own athanor's holdings, each place of the
// asking role with its subject, and every other athanor's only as a sum:
// no other athanor's name and no other role's subject is carried.
func TestHeldNamesOnlyTheAskersOwn(t *testing.T) {
	l := New(2600*mib, false)
	mine := session("ath_a", "mcp_mine")
	theirs := session("ath_b", "mcp_theirs")
	myBuild := &Entry{Role: "builds", Kind: "build", Athanor: "ath_a", Subject: "build_secret"}
	theirBuild := build("ath_b")
	for _, e := range []*Entry{mine, theirs, myBuild, theirBuild} {
		spawned(t, l, e, 0, 100*mib)
	}
	asking := session("ath_a", "mcp_next")
	l.Place(asking, at(1))
	ev := l.Tick(at(18))
	if len(ev.Refused) != 1 {
		t.Fatalf("refused %+v", ev.Refused)
	}
	want := Held{Need: 384 * mib, Free: (2600 - 384*2 - 800*2) * mib,
		Mine:   []Holding{{Kind: "program", Subject: "mcp_mine", Bytes: 384 * mib}, {Kind: "build", Bytes: 800 * mib}},
		Others: (384 + 800) * mib}
	if got := ev.Refused[0].Held; !reflect.DeepEqual(got, want) {
		t.Fatalf("held %+v, want %+v", got, want)
	}
}

// A session's athanor ceiling bounds its athanor's sessions alone.
func TestAnAthanorsCeilingBoundsItsSessions(t *testing.T) {
	l := New(4096*mib, false)
	a := session("ath_a", "p1")
	a.AthanorMax = 700 * mib
	admitted(t, l.Place(a, at(0)), a)
	theirBuild := build("ath_a")
	admitted(t, l.Place(theirBuild, at(0)), theirBuild)
	other := session("ath_b", "p2")
	admitted(t, l.Place(other, at(0)), other)
	b := session("ath_a", "p3")
	b.AthanorMax = 700 * mib
	if ev := l.Place(b, at(0)); len(ev.Admitted) != 0 {
		t.Fatalf("a second session past its athanor's ceiling: %+v", ev)
	}
	c := session("ath_a", "p4")
	c.AthanorMax = 300 * mib
	if ev := l.Place(c, at(0)); len(ev.Refused) != 1 {
		t.Fatalf("a session whose ceiling is below its allowance waits: %+v", ev)
	}
}

// An ending keeps its charge until it is free.
func TestAnEndingKeepsItsChargeUntilFree(t *testing.T) {
	l := New(1000*mib, false)
	a := session("ath_a", "p1")
	spawned(t, l, a, 0, 500*mib)
	l.Read(a, 500*mib, false, at(15))
	l.Ending(a, at(15))
	l.Read(a, 10*mib, false, at(16))
	if got := free(l, 16); got != 500*mib {
		t.Fatalf("an ending frees %d before it is free", got)
	}
	l.Drop(a, at(17))
	if got := free(l, 17); got != 1000*mib {
		t.Fatalf("free once it is free: %d", got)
	}
}

// A second with less than a program's allowance free asks idle runners to
// give way, as a waiting start does.
func TestASecondShortOfAProgramsAllowanceGivesWay(t *testing.T) {
	l := New(1000*mib, true)
	floor, kept := runner("runtime"), runner("runtime")
	spawned(t, l, floor, 0, 100*mib)
	spawned(t, l, kept, 0, 100*mib)
	l.Assign(kept, "warm", "ath_a", "", at(1))
	a := session("ath_b", "p1")
	spawned(t, l, a, 0, 400*mib)
	l.Read(kept, 100*mib, false, at(20))
	l.Read(a, 300*mib, false, at(20))
	if ev := l.Tick(at(20)); len(ev.GiveWay) != 0 {
		t.Fatalf("asked with 436 MiB free: %v", ev.GiveWay)
	}
	l.Read(a, 500*mib, false, at(21))
	if ev := l.Tick(at(21)); !slices.Equal(ev.GiveWay, []*Entry{kept}) {
		t.Fatalf("with 236 MiB free asked %v", ev.GiveWay)
	}
}

// A place spawned and never read, as one whose group's every read fails,
// keeps its allowance past its window: it never falls to nothing.
func TestAPlaceNeverReadKeepsItsAllowance(t *testing.T) {
	l := New(1000*mib, false)
	a := session("ath_a", "p1")
	admitted(t, l.Place(a, at(0)), a)
	l.Spawned(a, at(0))
	if got := l.charge(a, at(5)); got != Allowance(Session) {
		t.Fatalf("in its window: %d", got)
	}
	if got := l.charge(a, at(12)); got < Allowance(Session) {
		t.Fatalf("a session never read, past its window, is charged %d MiB, under its allowance", got/mib)
	}
}

// A refill of the floor never waits: the floor's runner given work while a
// build waits for room, the runtime's refill is admitted at once, past it.
func TestARefillDoesNotWaitBehindAStart(t *testing.T) {
	l := New(1300*mib, true)
	floor := runner("runtime")
	spawned(t, l, floor, 0, 120*mib)
	s := session("ath_a", "p1")
	spawned(t, l, s, 0, 700*mib)
	l.Read(s, 700*mib, false, at(20))
	// 1,136 beside F, 700 held: a build's 800 waits.
	b := build("ath_b")
	if ev := l.Place(b, at(20)); len(ev.Admitted) != 0 {
		t.Fatalf("the build fits: %+v", ev)
	}
	l.Assign(floor, "run", "ath_c", "", at(20.5))
	refill := runner("runtime")
	if ev := l.Place(refill, at(20.6)); !slices.Contains(ev.Admitted, refill) {
		t.Fatalf("the floor's refill waits behind the build: admitted %v", ev.Admitted)
	}
}

// Nor is it refused with the starts it came behind.
func TestARefillIsNeverRefused(t *testing.T) {
	l := New(1300*mib, true)
	floor := runner("runtime")
	spawned(t, l, floor, 0, 120*mib)
	s := session("ath_a", "p1")
	spawned(t, l, s, 0, 700*mib)
	l.Read(s, 700*mib, false, at(20))
	b1, b2 := build("ath_b"), build("ath_b")
	l.Place(b1, at(20))
	l.Place(b2, at(20.5))
	l.Assign(floor, "run", "ath_c", "", at(21))
	refill := runner("runtime")
	if ev := l.Place(refill, at(21)); !slices.Contains(ev.Admitted, refill) {
		t.Fatalf("the refill is not admitted at once: %+v", ev)
	}
	for sec := 22.0; sec <= 40; sec++ {
		l.Read(floor, 120*mib, false, at(sec))
		l.Read(s, 700*mib, false, at(sec))
		for _, r := range l.Tick(at(sec)).Refused {
			if r.Entry == refill {
				t.Fatalf("the floor's refill was refused at %vs: %+v", sec, r.Held)
			}
		}
	}
}

// An athanor at its own ceiling holds no other athanor's start: W has room
// for both, and only ath_a's ceiling stops its second session, which steps
// aside, is admitted once its athanor's charges allow, and is refused with
// held at 17 seconds otherwise.
func TestAnAthanorAtItsCeilingHoldsNoOtherAthanorsStart(t *testing.T) {
	l := New(4096*mib, false)
	a := session("ath_a", "p1")
	a.AthanorMax = 500 * mib
	admitted(t, l.Place(a, at(0)), a)
	a2 := session("ath_a", "p2")
	a2.AthanorMax = 500 * mib
	if ev := l.Place(a2, at(1)); len(ev.Admitted) != 0 || len(ev.GiveWay) != 0 {
		t.Fatalf("past its ceiling: %+v", ev)
	}
	other := session("ath_b", "p3")
	if ev := l.Place(other, at(1)); !slices.Contains(ev.Admitted, other) {
		t.Fatalf("ath_b's session, with %d MiB free, waits behind ath_a's ceiling", free(l, 1)/mib)
	}
	admitted(t, l.Drop(a, at(2)), a2)
	a3 := session("ath_a", "p4")
	a3.AthanorMax = 500 * mib
	l.Place(a3, at(3))
	ev := l.Tick(at(20))
	if len(ev.Refused) != 1 || ev.Refused[0].Entry != a3 || ev.Refused[0].Held.Need != 384*mib {
		t.Fatalf("a start held by its ceiling at 17 s: %+v", ev)
	}
}

// A start that waits for W still holds the order, a start held by its
// ceiling before it or not: a later one that fits does not pass it.
func TestAStartWaitingForWorkHoldsTheOrderPastACeiling(t *testing.T) {
	l := New(1600*mib, false)
	a := session("ath_a", "p1")
	a.AthanorMax = 400 * mib
	spawned(t, l, a, 0, 384*mib)
	held := session("ath_a", "p2")
	held.AthanorMax = 400 * mib
	b := build("ath_b")
	c := session("ath_c", "p3")
	l.Place(held, at(1))
	// 1,216 free: the build's 800 fits past the start its ceiling holds;
	// then 416, which a second build's 800 waits for, and c's 384, which
	// would fit, waits behind it.
	admitted(t, l.Place(b, at(1)), b)
	big := build("ath_d")
	if ev := l.Place(big, at(1)); len(ev.Admitted) != 0 {
		t.Fatalf("a second build fits: %+v", ev)
	}
	if ev := l.Place(c, at(1)); len(ev.Admitted) != 0 {
		t.Fatalf("a session passed the build waiting for W before it: %+v", ev)
	}
}

// An assign never changes a place's class: room was checked for a
// session's 384, and the place stays a session, charged so and counted in
// its athanor's ceiling.
func TestAnAssignAcrossClassesChangesNothing(t *testing.T) {
	l := New(4096*mib, false)
	a := session("ath_a", "p1")
	a.AthanorMax = 400 * mib
	admitted(t, l.Place(a, at(0)), a)
	if l.Assign(a, "build", "ath_a", "", at(0.1)) || a.Kind != "program" {
		t.Fatalf("a session's place was assigned a build's kind: %s", a.Kind)
	}
	if got := l.used(l.inFloor(), at(0.1)); got != 384*mib {
		t.Errorf("a place admitted with 384 MiB of room is charged %d", got/mib)
	}
	b := session("ath_a", "p2")
	b.AthanorMax = 400 * mib
	if ev := l.Place(b, at(0.2)); len(ev.Admitted) != 0 {
		t.Errorf("a second session of ath_a is admitted under a 400 MiB ceiling beside its first")
	}
	if !l.Assign(a, "terminal", "ath_a", "", at(0.3)) {
		t.Error("a session's place may not be assigned a terminal's kind")
	}
}

// An ask lasts one tick: a runner that turned an ask down, as one still
// spawning, is asked again at the next second, and the waiting start is
// served once it goes.
func TestAnAskLastsOneTick(t *testing.T) {
	l := New(1000*mib, true)
	floor, kept := runner("runtime"), runner("runtime")
	spawned(t, l, floor, 0, 100*mib)
	spawned(t, l, kept, 0, 300*mib)
	l.Assign(kept, "warm", "ath_a", "", at(1))
	s := session("ath_b", "p1")
	spawned(t, l, s, 0, 300*mib)
	l.Read(kept, 300*mib, false, at(20))
	l.Read(s, 300*mib, false, at(20))
	next := session("ath_c", "p2")
	if ev := l.Place(next, at(20)); !slices.Equal(ev.GiveWay, []*Entry{kept}) {
		t.Fatalf("asked %v", ev.GiveWay)
	}
	// The pool turned it down: no drop. The next second asks it again.
	l.Read(kept, 300*mib, false, at(21))
	if ev := l.Tick(at(21)); !slices.Equal(ev.GiveWay, []*Entry{kept}) {
		t.Fatalf("asked again %v", ev.GiveWay)
	}
	admitted(t, l.Drop(kept, at(21.5)), next)
}
