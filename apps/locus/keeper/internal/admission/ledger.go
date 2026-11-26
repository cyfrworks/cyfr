// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package admission

import (
	"slices"
	"time"
)

// Entry is one place in the ledger, from its `place` to its release. The
// keeper's place holds it; the ledger reads and writes it only under the
// keeper's lock, as every Ledger method runs.
type Entry struct {
	// Role is the name of the role whose place it is, and Floor whether
	// that role keeps the warm floor: only its runners are the floor's,
	// and only its places are asked to give way.
	Role  string
	Floor bool
	// Kind, Athanor and Subject are whose the place is at the moment.
	Kind, Athanor, Subject string
	// AthanorMax is the optional ceiling of the athanor's sessions on this
	// machine, a session's place's alone; 0 is none.
	AthanorMax uint64
	// Ref is the keeper's own handle of the place.
	Ref any

	admitted  bool
	ending    bool
	asked     bool
	placedAt  time.Time
	spawnedAt time.Time
	// assignedAt is its last assign, or its place while it had none.
	assignedAt time.Time
	reading    uint64
	lesser     bool
	readAt     time.Time
	// last is its last charge at a reading, which a place without a fresh
	// one is never charged under; frozen is an ending's charge.
	last   uint64
	frozen uint64
}

// Admitted says the place was given room.
func (e *Entry) Admitted() bool { return e.admitted }

func (e *Entry) class() Class { return Kinds[e.Kind] }

// fresh says it is a runner of the floor's role never given work: warm
// and no athanor's.
func (e *Entry) fresh() bool { return e.Floor && e.Kind == "warm" && e.Athanor == "" }

// kept says it is a runner at rest kept for its athanor.
func (e *Entry) kept() bool { return e.Floor && e.Kind == "warm" && e.Athanor != "" }

// Held says what holds a pool that refuses a start: what the start needs,
// what is free, the charges of the start's athanor (its subject only where
// the place is the asking role's) and the sum of everyone else's.
type Held struct {
	Need   uint64
	Free   uint64
	Mine   []Holding
	Others uint64
}

// Holding is one place of the start's athanor in a Held.
type Holding struct {
	Kind    string
	Subject string
	Bytes   uint64
}

// Refusal is a start refused for room.
type Refusal struct {
	Entry *Entry
	Held  Held
}

// Events are what one step of the ledger asks the keeper to send: places
// admitted, starts refused, and idle runners asked to give way, each in
// order.
type Events struct {
	Admitted []*Entry
	Refused  []Refusal
	GiveWay  []*Entry
}

func (ev *Events) merge(o Events) {
	ev.Admitted = append(ev.Admitted, o.Admitted...)
	ev.Refused = append(ev.Refused, o.Refused...)
	ev.GiveWay = append(ev.GiveWay, o.GiveWay...)
}

// Ledger is the one admission of a machine's Locus work (plan 2.9): every
// role's places, charged against W, with F kept apart where a role keeps
// the floor. It keeps no clock of its own: every step is given its now.
type Ledger struct {
	work      uint64
	floorKept bool
	admitted  []*Entry
	waiting   []*Entry
}

// New is the ledger of a pool of work W, F kept apart where floorKept.
func New(work uint64, floorKept bool) *Ledger {
	return &Ledger{work: work, floorKept: floorKept}
}

// Work is W.
func (l *Ledger) Work() uint64 { return l.work }

func (l *Ledger) floor() uint64 {
	if l.floorKept {
		return FloorBytes
	}
	return 0
}

// charge is e's charge at now: the larger of reading and allowance during
// the allowance's time, then the reading; a place whose reading is lesser,
// or that has none for StaleAfter, never under its allowance nor under its
// last charge; an ending's frozen charge.
func (l *Ledger) charge(e *Entry, now time.Time) uint64 {
	if e.ending {
		return e.frozen
	}
	allowance := Allowance(e.class())
	if e.spawnedAt.IsZero() || now.Before(e.spawnedAt.Add(AllowanceFor)) {
		return max(e.reading, allowance)
	}
	if e.lesser || e.readAt.IsZero() || now.Sub(e.readAt) >= StaleAfter {
		return max(e.reading, allowance, e.last)
	}
	return e.reading
}

// inFloor is the floor's runners: the oldest fresh runners admitted, up
// to FloorRunners, where the floor is kept.
func (l *Ledger) inFloor() map[*Entry]bool {
	in := map[*Entry]bool{}
	if !l.floorKept {
		return in
	}
	for _, e := range l.admitted {
		if len(in) == FloorRunners {
			break
		}
		if e.fresh() && !e.ending {
			in[e] = true
		}
	}
	return in
}

// used is the sum of every charge outside the floor.
func (l *Ledger) used(in map[*Entry]bool, now time.Time) uint64 {
	var used uint64
	for _, e := range l.admitted {
		if !in[e] {
			used += l.charge(e, now)
		}
	}
	return used
}

func (l *Ledger) free(in map[*Entry]bool, now time.Time) uint64 {
	return sub(sub(l.work, l.floor()), l.used(in, now))
}

// fillsFloor says e would be one of the floor's runners: a fresh runner
// while the floor has room for one. Its allowance is F, already held.
func (l *Ledger) fillsFloor(e *Entry, in map[*Entry]bool) bool {
	return l.floorKept && e.fresh() && len(in) < FloorRunners
}

// need is the room e needs beyond what is held for it.
func (l *Ledger) need(e *Entry, in map[*Entry]bool) uint64 {
	if l.fillsFloor(e, in) {
		return 0
	}
	return Allowance(e.class())
}

// sessions is the charge of the athanor's sessions.
func (l *Ledger) sessions(athanor string, now time.Time) uint64 {
	var sum uint64
	for _, e := range l.admitted {
		if e.class() == Session && e.Athanor == athanor {
			sum += l.charge(e, now)
		}
	}
	return sum
}

// fitsWork says e's allowance fits what W leaves now.
func (l *Ledger) fitsWork(e *Entry, in map[*Entry]bool, now time.Time) bool {
	return Allowance(e.class()) <= l.free(in, now)
}

// withinCeiling says e's allowance fits its athanor's own ceiling now.
func (l *Ledger) withinCeiling(e *Entry, now time.Time) bool {
	return e.AthanorMax == 0 || l.sessions(e.Athanor, now)+Allowance(e.class()) <= e.AthanorMax
}

// everFits says e could fit in a pool holding nothing else.
func (l *Ledger) everFits(e *Entry) bool {
	if l.floorKept && e.fresh() {
		return l.work >= FloorBytes
	}
	need := Allowance(e.class())
	return need <= sub(l.work, l.floor()) && (e.AthanorMax == 0 || need <= e.AthanorMax)
}

// Place enters a new place at now. A refill of an empty place of the floor
// is admitted at once, outside the queue, since F holds it; any other
// start goes behind every start already waiting: admitted at once if it
// fits and nothing waiting for W is before it, refused at once if it could
// never fit, else left waiting, and the idle runners that cover what is
// short are asked to give way.
func (l *Ledger) Place(e *Entry, now time.Time) Events {
	e.placedAt, e.assignedAt = now, now
	if !l.everFits(e) {
		return Events{Refused: []Refusal{{Entry: e, Held: l.held(e, l.inFloor(), now)}}}
	}
	if l.fillsFloor(e, l.inFloor()) {
		l.admit(e)
		ev := l.step(now, false)
		ev.Admitted = append([]*Entry{e}, ev.Admitted...)
		return ev
	}
	l.waiting = append(l.waiting, e)
	return l.step(now, false)
}

func (l *Ledger) admit(e *Entry) {
	e.admitted = true
	l.admitted = append(l.admitted, e)
}

// Drop takes e out, waiting or admitted, at its drop or its release, and
// admits what then fits.
func (l *Ledger) Drop(e *Entry, now time.Time) Events {
	l.waiting = slices.DeleteFunc(l.waiting, func(o *Entry) bool { return o == e })
	l.admitted = slices.DeleteFunc(l.admitted, func(o *Entry) bool { return o == e })
	return l.step(now, false)
}

// Spawned starts e's allowance's time.
func (l *Ledger) Spawned(e *Entry, now time.Time) { e.spawnedAt = now }

// Read stores e's reading.
func (l *Ledger) Read(e *Entry, bytes uint64, lesser bool, now time.Time) {
	e.reading, e.lesser, e.readAt = bytes, lesser, now
	e.last = l.charge(e, now)
}

// Assign gives e another kind of its class, athanor and subject: a runner
// given work leaves the floor and is charged by itself, and one at rest
// again may be asked to give way again. An assign to another class, which
// would dodge the room and the ceiling its place was admitted by, changes
// nothing and answers false.
func (l *Ledger) Assign(e *Entry, kind, athanor, subject string, now time.Time) bool {
	if c, ok := Kinds[kind]; !ok || c != e.class() {
		return false
	}
	e.Kind, e.Athanor, e.Subject = kind, athanor, subject
	e.assignedAt, e.asked = now, false
	return true
}

// Ending freezes e's charge until it is free.
func (l *Ledger) Ending(e *Entry, now time.Time) {
	if !e.ending {
		e.frozen = l.charge(e, now)
		e.ending = true
	}
}

// Tick is the ledger's second: starts admitted as room came, those that
// waited RoomWait refused, and idle runners asked for what is still short,
// a pool with less than a program's allowance free among it.
func (l *Ledger) Tick(now time.Time) Events { return l.step(now, true) }

func (l *Ledger) step(now time.Time, second bool) Events {
	var ev Events
	// In arrival order for room in W: none passes a start that waits for W
	// before it. A start that fits W but not its athanor's own ceiling
	// steps aside, holding no one, and is admitted when its athanor's
	// charges allow. A start that would fill an empty place of the floor,
	// a fresh runner become the floor's, needs no room and passes all.
	var kept []*Entry
	blocked := false
	for _, e := range l.waiting {
		in := l.inFloor()
		switch {
		case l.fillsFloor(e, in) && l.work >= FloorBytes:
		case blocked || !l.fitsWork(e, in, now):
			blocked = true
			kept = append(kept, e)
			continue
		case !l.withinCeiling(e, now):
			kept = append(kept, e)
			continue
		}
		l.admit(e)
		ev.Admitted = append(ev.Admitted, e)
	}
	l.waiting = kept
	if second {
		// An ask covers what is short only in the tick it was sent: one
		// still standing at the next may be asked again.
		for _, e := range l.admitted {
			e.asked = false
		}
	}
	in := l.inFloor()
	waiting := l.waiting[:0]
	for _, e := range l.waiting {
		if now.Sub(e.placedAt) >= RoomWait {
			ev.Refused = append(ev.Refused, Refusal{Entry: e, Held: l.held(e, in, now)})
			continue
		}
		waiting = append(waiting, e)
	}
	l.waiting = waiting
	ev.merge(Events{GiveWay: l.giveWay(in, now, second)})
	return ev
}

// giveWay asks, of the idle runners not yet asked, enough to cover what
// the waiting starts need beyond what is free and what those already asked
// will give: kept ones oldest first, then fresh ones above the floor. A
// second with less than a program's allowance free asks alike.
func (l *Ledger) giveWay(in map[*Entry]bool, now time.Time, second bool) []*Entry {
	var need uint64
	for _, e := range l.waiting {
		// A start held by its athanor's ceiling alone needs no room of W.
		if l.fitsWork(e, in, now) && !l.withinCeiling(e, now) {
			continue
		}
		need += l.need(e, in)
	}
	if second {
		need = max(need, Allowance(Session))
	}
	free := l.free(in, now)
	if need <= free {
		return nil
	}
	short := need - free
	var kept, fresh []*Entry
	for _, e := range l.admitted {
		switch {
		case e.ending || in[e]:
		case e.kept():
			kept = append(kept, e)
		case e.fresh():
			fresh = append(fresh, e)
		}
	}
	slices.SortStableFunc(kept, func(a, b *Entry) int { return a.assignedAt.Compare(b.assignedAt) })
	var asked []*Entry
	for _, e := range append(kept, fresh...) {
		if short == 0 {
			break
		}
		short = sub(short, l.charge(e, now))
		if !e.asked {
			e.asked = true
			asked = append(asked, e)
		}
	}
	return asked
}

// held is the account of the pool a refusal of e carries.
func (l *Ledger) held(e *Entry, in map[*Entry]bool, now time.Time) Held {
	h := Held{Need: l.need(e, in), Free: l.free(in, now), Mine: []Holding{}}
	var mine uint64
	for _, o := range l.admitted {
		if in[o] || o == e {
			continue
		}
		c := l.charge(o, now)
		if e.Athanor != "" && o.Athanor == e.Athanor {
			holding := Holding{Kind: o.Kind, Bytes: c}
			if o.Role == e.Role {
				holding.Subject = o.Subject
			}
			h.Mine = append(h.Mine, holding)
			mine += c
		}
	}
	h.Others = l.used(in, now) - mine
	return h
}
