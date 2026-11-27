// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package admission

import (
	"math/bits"
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
	// Machine is the place of the person's VM a session runs in (NewMachine),
	// whose one charge holds it: the session is charged nothing of its own,
	// and its readings, the guest's, are counted under its subject alone.
	// nil for a place on the host.
	Machine *Entry

	// vm says the place is a person's VM's own (NewMachine): the keeper's,
	// of no kind, counted in no counter, admitted with its first session.
	vm bool
	// base is, for a session in a VM, the VM's reading at the session's
	// admission: while its allowance's time runs, the VM is charged at
	// least that and the allowances of its sessions still starting.
	base       uint64
	admittedAt time.Time

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
	// counted is the counter its latest reading is in, and countedBytes the
	// bytes it put there; nil before its first reading, or uncounted.
	counted      *counter
	countedBytes uint64
}

// Admitted says the place was given room.
func (e *Entry) Admitted() bool { return e.admitted }

// NewMachine is the place of athanor's VM, which role's sessions of that
// athanor run in: each such session's place names it as its Machine before
// it is placed. It is no role's kind and is in no counter: the host is
// charged once for the VM, by its reading, and its sessions' readings are
// subjects under it, never added to it. It is admitted with the first of
// its sessions that is, its own allowance, MachineBytes, beside that
// session's, charged from then until AllowanceFor after its Spawned, the
// VMM's start; Drop takes it out at the VM's release.
func NewMachine(role, athanor string, ref any) *Entry {
	return &Entry{Role: role, Athanor: athanor, Ref: ref, vm: true}
}

// IsMachine says the place is a person's VM's own.
func (e *Entry) IsMachine() bool { return e.vm }

func (e *Entry) class() Class { return Kinds[e.Kind] }

// startNeed is the room e's start needs: its class's allowance, and the
// VM's own beside it for a session whose VM is not yet admitted, the start
// that boots it.
func (e *Entry) startNeed() uint64 {
	need := Allowance(e.class())
	if e.Machine != nil && !e.Machine.admitted {
		need += MachineBytes
	}
	return need
}

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
// the floor, and what it counts of who used what (counters). It keeps no
// clock of its own: every step is given its now.
type Ledger struct {
	work      uint64
	floorKept bool
	admitted  []*Entry
	waiting   []*Entry
	counters  counters
}

// New is the ledger of a pool of work W, F kept apart where floorKept.
func New(work uint64, floorKept bool) *Ledger {
	return &Ledger{work: work, floorKept: floorKept, counters: newCounters()}
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
	switch {
	case e.vm:
		return l.machineCharge(e, now)
	case e.Machine != nil:
		return 0
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

// machineCharge is a VM's charge at now: the larger of its reading and
// what its starts hold, its own MachineBytes from its admission until
// AllowanceFor after its VMM's start, and, while any of its sessions'
// allowances' time runs, the VM's reading at the earliest such session's
// admission with the allowances of every one of them; a reading that is
// lesser, or none for StaleAfter, never under its last charge.
func (l *Ledger) machineCharge(m *Entry, now time.Time) uint64 {
	var held uint64
	if m.spawnedAt.IsZero() || now.Before(m.spawnedAt.Add(AllowanceFor)) {
		held = MachineBytes
	}
	var earliest *Entry
	for _, e := range l.admitted {
		if e.Machine != m || !e.spawnedAt.IsZero() && !now.Before(e.spawnedAt.Add(AllowanceFor)) {
			continue
		}
		held += Allowance(e.class())
		if earliest == nil || e.admittedAt.Before(earliest.admittedAt) {
			earliest = e
		}
	}
	if earliest != nil {
		held += earliest.base
	}
	reading := m.reading
	if m.lesser || m.readAt.IsZero() || now.Sub(m.readAt) >= StaleAfter {
		reading = max(reading, m.last)
	}
	return max(reading, held)
}

// sessionsIn is how many places are admitted in the VM m.
func (l *Ledger) sessionsIn(m *Entry) int {
	n := 0
	for _, e := range l.admitted {
		if e.Machine == m {
			n++
		}
	}
	return n
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
	return e.startNeed()
}

// sessions is the charge of the athanor's sessions: those on the host, and
// its VM's, which holds every one of its sessions there.
func (l *Ledger) sessions(athanor string, now time.Time) uint64 {
	var sum uint64
	for _, e := range l.admitted {
		if e.Athanor == athanor && (e.vm || e.class() == Session && e.Machine == nil) {
			sum += l.charge(e, now)
		}
	}
	return sum
}

// fitsWork says e's start fits what W leaves now.
func (l *Ledger) fitsWork(e *Entry, in map[*Entry]bool, now time.Time) bool {
	return e.startNeed() <= l.free(in, now)
}

// withinCeiling says e's start fits its athanor's own ceiling now.
func (l *Ledger) withinCeiling(e *Entry, now time.Time) bool {
	return e.AthanorMax == 0 || l.sessions(e.Athanor, now)+e.startNeed() <= e.AthanorMax
}

// everFits says e could fit in a pool holding nothing else.
func (l *Ledger) everFits(e *Entry) bool {
	if l.floorKept && e.fresh() {
		return l.work >= FloorBytes
	}
	need := e.startNeed()
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
		l.admit(e, now)
		ev := l.step(now, false)
		ev.Admitted = append([]*Entry{e}, ev.Admitted...)
		return ev
	}
	l.waiting = append(l.waiting, e)
	return l.step(now, false)
}

// admit gives e room, at now: a session whose VM is not yet admitted
// admits it with it, in the same step, and one in a VM takes the VM's
// reading as its base.
func (l *Ledger) admit(e *Entry, now time.Time) {
	if m := e.Machine; m != nil {
		if !m.admitted {
			m.admitted, m.admittedAt, m.assignedAt = true, now, now
			l.admitted = append(l.admitted, m)
		}
		e.base = m.reading
	}
	e.admitted, e.admittedAt = true, now
	l.admitted = append(l.admitted, e)
}

// Drop takes e out, waiting or admitted, at its drop or its release, its
// bytes out of their counter with it, and admits what then fits.
// A session in a VM leaves it at rest from now when it was the VM's last,
// which then may be asked to give way. A VM is dropped at its release,
// after every session in it.
func (l *Ledger) Drop(e *Entry, now time.Time) Events {
	l.waiting = slices.DeleteFunc(l.waiting, func(o *Entry) bool { return o == e })
	was := e.admitted
	l.admitted = slices.DeleteFunc(l.admitted, func(o *Entry) bool { return o == e })
	l.counters.withdraw(e, now)
	if m := e.Machine; m != nil && was && l.sessionsIn(m) == 0 {
		m.assignedAt, m.asked = now, false
	}
	return l.step(now, false)
}

// Detach takes a session placed in a VM out of it, as when its spawn runs
// on the host after all: from now it is charged by itself, its start's
// allowance from its admission as any session's.
func (l *Ledger) Detach(e *Entry, now time.Time) Events {
	m := e.Machine
	if m == nil {
		return Events{}
	}
	e.Machine, e.base = nil, 0
	if e.admitted && l.sessionsIn(m) == 0 {
		m.assignedAt, m.asked = now, false
	}
	return l.step(now, false)
}

// Sessions is how many places are admitted in the VM m: none is a VM at
// rest.
func (l *Ledger) Sessions(m *Entry) int { return l.sessionsIn(m) }

// Spawned starts e's allowance's time.
func (l *Ledger) Spawned(e *Entry, now time.Time) { e.spawnedAt = now }

// Read stores e's reading and counts it: the time since its last reading
// is measured where it is within ReadingGap, and a first reading measures
// none.
// A VM's reading is its charge's alone, in no counter.
func (l *Ledger) Read(e *Entry, bytes uint64, lesser bool, now time.Time) {
	if e.vm {
		e.reading, e.lesser, e.readAt = bytes, lesser, now
		e.last = l.charge(e, now)
		return
	}
	var gap time.Duration
	if !e.readAt.IsZero() {
		if since := now.Sub(e.readAt); since > 0 && since <= ReadingGap {
			gap = since
		}
	}
	l.counters.read(e, bytes, gap, now)
	e.reading, e.lesser, e.readAt = bytes, lesser, now
	e.last = l.charge(e, now)
}

// Assign gives e another kind of its class, athanor and subject: a runner
// given work leaves the floor and is charged by itself, and one at rest
// again may be asked to give way again, and its bytes go at once to the
// counter of whose it now is. An assign to another class, which would
// dodge the room and the ceiling its place was admitted by, changes
// nothing and answers false.
func (l *Ledger) Assign(e *Entry, kind, athanor, subject string, now time.Time) bool {
	if c, ok := Kinds[kind]; !ok || c != e.class() {
		return false
	}
	e.Kind, e.Athanor, e.Subject = kind, athanor, subject
	e.assignedAt, e.asked = now, false
	l.counters.move(e, now)
	return true
}

// Killed counts a kill for memory at e's release at now, its cause an
// `exited`'s `memory` (KillCap, KillMachine or KillEither), in the counter
// of e's key on that day, made for it where e was never read.
func (l *Ledger) Killed(e *Entry, cause string, now time.Time) {
	l.counters.killed(e, cause, now)
}

// Report is the role's counters whose rev is past after, by rev, at most
// ReportCounters, beside the machine's numbers at now. Another role's
// counters are never in it.
func (l *Ledger) Report(role string, after uint64, now time.Time) Report {
	page, next := l.counters.report(role, after)
	return Report{Work: l.work, Floor: l.floor(), Used: l.used(l.inFloor(), now), Counters: page, Next: next}
}

// Uncounted is how many uses went uncounted since the ledger was made,
// every counter held and none free to go.
func (l *Ledger) Uncounted() uint64 { return l.counters.uncounted }

// Ending freezes e's charge until it is free.
func (l *Ledger) Ending(e *Entry, now time.Time) {
	if !e.ending {
		e.frozen = l.charge(e, now)
		e.ending = true
	}
}

// Tick is the ledger's second: starts admitted as room came, those that
// waited RoomWait refused, and idle runners asked for what is still short,
// a pool with less than a program's allowance free among it. At a day's
// end each admitted place's bytes go to its counter of the new day, so a
// counter holding bytes changes at least daily, and only then are the
// counters past CounterKeep let go.
func (l *Ledger) Tick(now time.Time) Events {
	for _, e := range l.admitted {
		l.counters.move(e, now)
	}
	l.counters.sweep(now)
	return l.step(now, true)
}

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
		l.admit(e, now)
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

// giveWay asks, of the idle work not yet asked, enough to cover what the
// waiting starts need beyond what is free and what those already asked
// will give: kept runners and VMs at rest, which hold no session, oldest at
// rest first, then fresh runners above the floor. A VM a waiting start
// would run in is not asked: that start needs it. A second with less than a
// program's allowance free asks alike.
func (l *Ledger) giveWay(in map[*Entry]bool, now time.Time, second bool) []*Entry {
	var need uint64
	for _, e := range l.waiting {
		// A start over its athanor's ceiling asks no one: no runner of
		// another athanor goes for a start its own limit holds, whether W
		// is short too or not.
		if !l.withinCeiling(e, now) {
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
	needed := map[*Entry]bool{}
	for _, e := range l.waiting {
		if e.Machine != nil {
			needed[e.Machine] = true
		}
	}
	var kept, fresh []*Entry
	for _, e := range l.admitted {
		switch {
		case e.ending || in[e]:
		case e.kept(), e.vm && !needed[e] && l.sessionsIn(e) == 0:
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

// held is the account of the pool a refusal of e carries. A VM is no
// holding of its own: each session in it holds its reading and its even
// share of what the VM's charge holds beyond its sessions' readings, so
// the VM's sessions together hold its charge.
func (l *Ledger) held(e *Entry, in map[*Entry]bool, now time.Time) Held {
	h := Held{Need: l.need(e, in), Free: l.free(in, now), Mine: []Holding{}}
	var mine uint64
	for _, o := range l.admitted {
		if in[o] || o == e || o.vm {
			continue
		}
		c := l.charge(o, now)
		if o.Machine != nil {
			c = l.shareOf(o, now)
		}
		if e.Athanor != "" && o.Athanor == e.Athanor {
			holding := Holding{Kind: o.Kind, Bytes: c}
			if o.Role == e.Role {
				holding.Subject = o.Subject
			}
			h.Mine = append(h.Mine, holding)
			mine += c
		}
	}
	h.Others = sub(l.used(in, now), mine)
	return h
}

// shareOf is what the session o holds of its VM's charge: its own reading
// and an even share of the rest, the first of the VM's sessions taking
// what does not divide; or, where their readings pass the charge, its part
// of the charge by its reading. The VM's sessions together hold its charge.
func (l *Ledger) shareOf(o *Entry, now time.Time) uint64 {
	var readings uint64
	var in []*Entry
	for _, e := range l.admitted {
		if e.Machine == o.Machine {
			readings += e.reading
			in = append(in, e)
		}
	}
	total := l.charge(o.Machine, now)
	n := uint64(len(in))
	parts := make([]uint64, len(in))
	var given uint64
	for i, e := range in {
		if readings <= total {
			parts[i] = e.reading + (total-readings)/n
		} else {
			hi, lo := bits.Mul64(e.reading, total)
			parts[i], _ = bits.Div64(hi, lo, readings)
		}
		given += parts[i]
	}
	parts[0] += total - given
	return parts[slices.Index(in, o)]
}
