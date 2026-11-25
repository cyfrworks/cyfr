// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package serve

import (
	"sync"
	"time"

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

// place is one piece of work the keeper follows from before its preparation
// to its release (the protocol's package doc says how): whose it is, whether
// a spawn has named it, the spawn made in it and that spawn's last reading.
type place struct {
	whose protocol.Whose
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

// handlePlace holds a place of a new id, answered `placed`; one of an id the
// keeper already holds is refused.
func (s *server) handlePlace(c *client, req *protocol.Request) {
	s.mu.Lock()
	_, held := c.places[req.ID]
	if !held {
		c.places[req.ID] = &place{whose: whoseOf(req)}
	}
	s.mu.Unlock()
	if held {
		s.log.Warn("place %s refused: role %s already holds it", req.ID, c.role.spec.Name)
		s.send(c, protocol.NewError(req.ID, "", protocol.CodeBadRequest))
		return
	}
	s.send(c, protocol.NewPlaced(req.ID))
}

// handleDrop frees a place no spawn has named; a named one is freed with its
// spawn. It answers nothing.
func (s *server) handleDrop(c *client, req *protocol.Request) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if p := c.places[req.Place]; p != nil && !p.named {
		delete(c.places, req.Place)
	}
}

// handleAssign makes a place whose the request says, an athanor or a subject
// it does not name cleared, answered `assigned`; an assign of a place the
// keeper does not hold, or naming another athanor than the one whose packs
// its spawn binds, is refused.
func (s *server) handleAssign(c *client, req *protocol.Request) {
	s.mu.Lock()
	p := c.places[req.Place]
	bound := p != nil && p.packs != "" && p.packs != req.Athanor
	if p != nil && !bound {
		p.whose = whoseOf(req)
	}
	s.mu.Unlock()
	switch {
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
	// claimNone: c holds no such place, or another spawn named it.
	claimNone
	// claimOthersPacks: the spawn names packs not its place's athanor's,
	// or of a role that keeps none; the place is freed.
	claimOthersPacks
)

// claimPlace has a starting spawn of c name its place. Whose packs it
// binds is decided in the same step, under s.mu: only its place's
// athanor's, of the kept role whose keeper keeps them, and from here the
// place keeps that athanor (handleAssign), so the athanor checked is the
// athanor bound.
func (s *server) claimPlace(c *client, req *protocol.Request) claim {
	s.mu.Lock()
	defer s.mu.Unlock()
	p := c.places[req.Place]
	if p == nil || p.named {
		return claimNone
	}
	if req.Packs != nil {
		if req.Packs.Athanor != p.whose.Athanor || s.packs == nil || !c.role.spec.Kept {
			delete(c.places, req.Place)
			return claimOthersPacks
		}
		p.packs = req.Packs.Athanor
	}
	p.named = true
	return claimed
}

// madeIn makes sp the spawn made in the place id it claimed: from here its
// retirement frees the place, and no refusal does.
func (s *server) madeIn(id string, sp *spawn) {
	s.mu.Lock()
	defer s.mu.Unlock()
	sp.place = id
	sp.client.places[id].spawn = sp
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

// reader reads every live spawn's group, and retries the removal of every
// group a retirement could not remove, each readEvery until stop closes.
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
