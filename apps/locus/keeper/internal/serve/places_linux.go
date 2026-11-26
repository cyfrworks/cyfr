// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package serve

import (
	"sync"
	"time"

	"github.com/cyfr/locus/keeper/internal/admission"
	"github.com/cyfr/locus/keeper/internal/cgroup"
	"github.com/cyfr/locus/keeper/internal/protocol"
)

// readEvery is how often the reader reads every live spawn's group and
// retries the removal of every group a retirement could not remove.
var readEvery = time.Second

// readUse is the reader's one read of a group, removeGroup a retirement's
// removal of one, and now the clock readings and their ages are told by.
var (
	readUse     = (*cgroup.Group).Used
	removeGroup = (*cgroup.Group).Remove
	now         = time.Now
)

// limitsOf is the bounds the keeper sets a spawn of a kind to, on a pool
// of work W (admission.LimitsOf); a test sets the bound its spawns' work
// needs.
var limitsOf = admission.LimitsOf

// place is one piece of work the keeper follows from before its preparation
// to its release (the protocol's package doc says how): whose it is, whether
// a spawn has named it, the spawn made in it and that spawn's last reading.
type place struct {
	whose protocol.Whose
	// entry is the place in the keeper's one admission (s.ledger): it has
	// room once entry.Admitted(), and only then may a spawn name it.
	entry *admission.Entry
	// named says a spawn has claimed the place: no drop frees it and no
	// other spawn may name it.
	named bool
	// spawn is the spawn made in the place, nil while its claim has made
	// none: a refusal before then frees the place, and from then only that
	// spawn's retirement does, in the step its group is removed, whether
	// the spawn started or was refused.
	spawn *spawn
	// reading is the last reading of its spawn's group, taken at readAt; a
	// zero readAt is no reading yet.
	reading protocol.Reading
	readAt  time.Time
	// packs is the athanor whose packs its spawn binds, fixed at its claim
	// (claimPlace): an assign naming another is refused.
	packs string
}

// removal is what a retirement whose group could not be removed leaves to
// the reader's retry: whether to send `released` once the group is gone,
// and whether a pooled spawn's uid was found clean, to go back to its pool
// then. A kept spawn's is never clean: its uid is no pool's.
type removal struct {
	notify bool
	clean  bool
	// trying says a retry of the removal is out.
	trying bool
}

func whoseOf(req *protocol.Request) protocol.Whose {
	return protocol.Whose{Kind: req.Kind, Athanor: req.Athanor, Subject: req.Subject}
}

// placeRef is what a ledger entry's Ref holds: whose channel its place is
// on, and its id there.
type placeRef struct {
	c  *client
	id string
}

// kindOfRole says whether c's role places and assigns kind: the role that
// keeps the floor its runners' kinds alone, every other role every other
// kind.
func kindOfRole(c *client, kind string) bool {
	return admission.FloorKind(kind) == c.role.spec.Floor
}

// handlePlace enters a place of a new id in the keeper's one admission,
// answered `placed` once it has room or refused `no_memory` (admit); one
// of an id the keeper already holds, or of a kind its role does not place,
// is refused at once.
func (s *server) handlePlace(c *client, req *protocol.Request) {
	if !kindOfRole(c, req.Kind) {
		s.log.Warn("place %s refused: role %s does not place a %s", req.ID, c.role.spec.Name, req.Kind)
		s.send(c, protocol.NewError(req.ID, "", protocol.CodeBadRequest))
		return
	}
	s.mu.Lock()
	_, held := c.places[req.ID]
	if !held {
		e := &admission.Entry{Role: c.role.spec.Name, Floor: c.role.spec.Floor, Kind: req.Kind,
			Athanor: req.Athanor, Subject: req.Subject, Ref: placeRef{c: c, id: req.ID}}
		if req.AthanorMax != nil {
			e.AthanorMax = *req.AthanorMax
		}
		c.places[req.ID] = &place{whose: whoseOf(req), entry: e}
		s.admit(s.ledger.Place(e, now()))
	}
	s.mu.Unlock()
	if held {
		s.log.Warn("place %s refused: role %s already holds it", req.ID, c.role.spec.Name)
		s.send(c, protocol.NewError(req.ID, "", protocol.CodeBadRequest))
		return
	}
	s.drain(c)
}

// handleDrop frees a place no spawn has named, one still waiting for room
// among them; a named one is freed with its spawn. It answers nothing.
func (s *server) handleDrop(c *client, req *protocol.Request) {
	s.mu.Lock()
	if p := c.places[req.Place]; p != nil && !p.named {
		s.freePlace(c, req.Place)
	}
	s.mu.Unlock()
	s.drain(c)
}

// freePlace frees c's place id, in the keeper's admission too, with s.mu
// held: what then fits is queued for its clients.
func (s *server) freePlace(c *client, id string) {
	if p := c.places[id]; p != nil {
		delete(c.places, id)
		s.admit(s.ledger.Drop(p.entry, now()))
	}
}

// ending freezes the charge of sp's place until it is free, with s.mu held.
func (s *server) ending(sp *spawn) {
	if p := sp.client.places[sp.place]; p != nil && p.spawn == sp {
		s.ledger.Ending(p.entry, now())
	}
}

// admit queues, with s.mu held, what a step of the admission asks the
// keeper to send, on each client's own queue in its order (client.queue):
// each place admitted is answered `placed` with its spawn's memory bound,
// each start refused is freed and answered `no_memory` with what holds the
// memory, and each idle runner asked to give way is named to its role. No
// step waits for a line to be written: a client that stops reading holds
// only its own lines.
func (s *server) admit(ev admission.Events) {
	for _, e := range ev.Admitted {
		ref := e.Ref.(placeRef)
		limits := limitsOf(e.Kind, s.ledger.Work())
		ref.c.queue(protocol.NewPlaced(ref.id, limits.MemoryBytes))
	}
	for _, r := range ev.Refused {
		ref := r.Entry.Ref.(placeRef)
		delete(ref.c.places, ref.id)
		s.log.Warn("place %s of role %s refused: no room in the pool for a %s (needs %s, %s free)", ref.id,
			ref.c.role.spec.Name, r.Entry.Kind, describeBytes(r.Held.Need), describeBytes(r.Held.Free))
		ref.c.queue(protocol.NewNoMemory(ref.id, heldOf(r.Held)))
	}
	for _, e := range ev.GiveWay {
		ref := e.Ref.(placeRef)
		ref.c.queue(protocol.NewGiveWay(ref.id))
	}
}

func heldOf(h admission.Held) protocol.Held {
	held := protocol.Held{Need: h.Need, Free: h.Free, Others: h.Others, Mine: make([]protocol.Holding, 0, len(h.Mine))}
	for _, m := range h.Mine {
		held.Mine = append(held.Mine, protocol.Holding{Kind: m.Kind, Subject: m.Subject, Bytes: m.Bytes})
	}
	return held
}

// admitTick is the admission's second: starts admitted as room came,
// those that waited their time refused, idle runners asked to give way.
func (s *server) admitTick() {
	s.mu.Lock()
	s.admit(s.ledger.Tick(now()))
	s.mu.Unlock()
}

// handleAssign makes a place whose the request says, an athanor or a subject
// it does not name cleared, answered `assigned`; an assign of a place the
// keeper does not hold, or naming another athanor than the one whose packs
// its spawn binds, is refused.
func (s *server) handleAssign(c *client, req *protocol.Request) {
	if !c.role.spec.Floor || !kindOfRole(c, req.Kind) {
		s.log.Warn("assign %s refused: role %s does not assign a %s", req.ID, c.role.spec.Name, req.Kind)
		s.send(c, protocol.NewError(req.ID, "", protocol.CodeBadRequest))
		return
	}
	s.mu.Lock()
	p := c.places[req.Place]
	bound := p != nil && p.packs != "" && p.packs != req.Athanor
	other := false
	if p != nil && !bound {
		if other = !s.ledger.Assign(p.entry, req.Kind, req.Athanor, req.Subject, now()); !other {
			p.whose = whoseOf(req)
		}
	}
	s.mu.Unlock()
	switch {
	case other:
		s.log.Warn("assign %s refused: place %s is of another class than a %s", req.ID, req.Place, req.Kind)
	case p == nil:
		s.log.Warn("assign %s refused: role %s holds no place %s", req.ID, c.role.spec.Name, req.Place)
	case bound:
		s.log.Warn("assign %s refused: the spawn of place %s binds its athanor's packs", req.ID, req.Place)
	default:
		s.send(c, protocol.NewAssigned(req.ID))
		return
	}
	s.send(c, protocol.NewError(req.ID, "", protocol.CodeBadRequest))
}

// What a spawn's claim of its place came to.
type claim int

const (
	claimed claim = iota
	// claimNone: c holds no such place, one still waiting for room, or
	// one another spawn named.
	claimNone
	// claimOthersPacks: the spawn names packs not its place's athanor's,
	// or of a role that keeps none; the place is freed.
	claimOthersPacks
)

// claimPlace has a starting spawn of c name its place. Whose packs it
// binds is decided in the same step, under s.mu: only its place's
// athanor's, of the kept role whose keeper keeps them, and from here the
// place keeps that athanor (handleAssign), so the athanor checked is the
// athanor bound. A claimed spawn's bounds are those of its place's kind at
// its claim.
func (s *server) claimPlace(c *client, req *protocol.Request) (claim, admission.Limits) {
	s.mu.Lock()
	defer s.mu.Unlock()
	p := c.places[req.Place]
	if p == nil || p.named || !p.entry.Admitted() {
		return claimNone, admission.Limits{}
	}
	if req.Packs != nil {
		if req.Packs.Athanor != p.whose.Athanor || s.packs == nil || !c.role.spec.Kept {
			s.freePlace(c, req.Place)
			return claimOthersPacks, admission.Limits{}
		}
		p.packs = req.Packs.Athanor
	}
	p.named = true
	return claimed, limitsOf(p.whose.Kind, s.ledger.Work())
}

// madeIn makes sp the spawn made in the place id it claimed: from here its
// retirement frees the place, and no refusal does.
func (s *server) madeIn(id string, sp *spawn) {
	s.mu.Lock()
	defer s.mu.Unlock()
	sp.place = id
	p := sp.client.places[id]
	p.spawn = sp
	s.ledger.Spawned(p.entry, now())
}

// handleMeasure answers whose a place is, its last reading and that
// reading's age, from what the reader stored: it never reads a group itself.
func (s *server) handleMeasure(c *client, req *protocol.Request) {
	var reply any = protocol.NewError(req.ID, "", protocol.CodeUnmeasured)
	s.mu.Lock()
	if p := c.places[req.Place]; p != nil && !p.readAt.IsZero() {
		reply = protocol.NewMeasured(req.ID, p.whose, p.reading, uint64(now().Sub(p.readAt).Milliseconds()))
	}
	s.mu.Unlock()
	s.send(c, reply)
}

// reader reads every live spawn's group, retries the removal of every
// group a retirement could not remove, and steps the admission's second
// (admitTick), each readEvery until stop closes.
func (s *server) reader(stop <-chan struct{}) {
	tick := time.NewTicker(readEvery)
	defer tick.Stop()
	for {
		select {
		case <-stop:
			return
		case <-tick.C:
			s.read()
			s.retryRemovals()
			s.admitTick()
		}
	}
}

// read starts a read of the group of every live spawn, and of every one a
// retirement could not remove, each on a goroutine of its own, outside mu:
// no read however slow holds back a request or another group's read. A
// group whose read is still out is not read again until it returns, its
// place keeping the last reading meanwhile. A reading is stored only while
// the place still names that spawn: a pooled spawn's group is named by its
// uid, which another spawn may take once this one's group is gone, and the
// place goes in the step the group does. A read that fails leaves the last
// reading as it was. A read of a group the kernel serves returns at once,
// and ends with an error once its group is removed, whether the removal
// came before its open of memory.stat or between its open and its read: a
// goroutine is left behind its spawn only by a read that never returns,
// which the kernel's cgroup files do not do, so only a test's gate that
// stays closed leaves one. It answers a wait for the reads it started,
// which the reader does not wait for.
func (s *server) read() (wait func()) {
	// The seams are read here, on the caller's goroutine, which a test that
	// sets them joins before it puts them back.
	use, clock := readUse, now
	s.mu.Lock()
	due := make([]*spawn, 0, len(s.spawns)+len(s.unremoved))
	for _, sp := range s.spawns {
		due = append(due, sp)
	}
	for sp := range s.unremoved {
		due = append(due, sp)
	}
	s.mu.Unlock()
	var reads sync.WaitGroup
	for _, sp := range due {
		if !sp.reading.CompareAndSwap(false, true) {
			continue
		}
		reads.Add(1)
		go func() {
			defer reads.Done()
			defer sp.reading.Store(false)
			got, err := use(sp.group)
			if err != nil {
				return
			}
			at := clock()
			s.mu.Lock()
			defer s.mu.Unlock()
			if p := sp.client.places[sp.place]; p != nil && p.spawn == sp {
				p.reading, p.readAt = protocol.Reading{Bytes: got.Bytes, Lesser: got.Lesser}, at
				s.ledger.Read(p.entry, got.Bytes, got.Lesser, at)
			}
		}()
	}
	return reads.Wait
}

// retryRemovals retries the removal of every group a retirement could not
// remove, each on a goroutine of its own and one retry at a time per group,
// so that a removal however slow (it waits up to two seconds for the
// group's last process) delays no read. The retry that removes a group
// finishes its retirement: the spawn leaves spawns with its place, a clean
// pooled uid goes back to its pool, its egress cleared first, and the
// `released` is sent. It answers a wait for the retries it started, which
// the reader does not wait for.
func (s *server) retryRemovals() (wait func()) {
	remove := removeGroup
	s.mu.Lock()
	var due []*spawn
	for sp, r := range s.unremoved {
		if !r.trying {
			r.trying = true
			due = append(due, sp)
		}
	}
	s.mu.Unlock()
	var retries sync.WaitGroup
	for _, sp := range due {
		retries.Add(1)
		go func() {
			defer retries.Done()
			s.retryRemoval(sp, remove)
		}()
	}
	return retries.Wait
}

func (s *server) retryRemoval(sp *spawn, remove func(*cgroup.Group) error) {
	err := remove(sp.group)
	s.mu.Lock()
	r := s.unremoved[sp]
	if err != nil {
		r.trying = false
	}
	s.mu.Unlock()
	if err != nil {
		return
	}
	s.mu.Lock()
	if r.clean {
		_ = sp.pool.Release(sp.account.UID)
	}
	s.forget(sp)
	delete(s.unremoved, sp)
	s.mu.Unlock()
	s.log.Info("spawn %s: its memory group of uid %d removed on a retry; retired", sp.id, sp.account.UID)
	if r.notify {
		s.send(sp.client, protocol.NewReleased(sp.id))
	}
}
