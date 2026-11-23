// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package serve

import (
	"time"

	"github.com/cyfr/locus/keeper/internal/cgroup"
	"github.com/cyfr/locus/keeper/internal/protocol"
)

// readEvery is how often the reader reads every live spawn's group.
var readEvery = time.Second

// readUse is the reader's one read of a group, and now the clock its
// readings and their ages are told by.
var (
	readUse = (*cgroup.Group).Used
	now     = time.Now
)

// place is one piece of work the keeper follows from before its preparation
// to its release (the protocol's package doc says how): whose it is, whether
// a spawn has named it, and that spawn's last reading.
type place struct {
	whose protocol.Whose
	// named says a spawn has claimed the place: no drop frees it and no
	// other spawn may name it. That spawn's refusal frees it, and so does
	// the retirement of a spawn that started, at its `released`.
	named bool
	// reading is the last reading of its spawn's group, taken at readAt; a
	// zero readAt is no reading yet.
	reading protocol.Reading
	readAt  time.Time
}

func whoseOf(req *protocol.Request) protocol.Whose {
	return protocol.Whose{Kind: req.Kind, Athanor: req.Athanor, Subject: req.Subject}
}

// handlePlace holds a place of a new id, answered `placed`; one of an id the
// keeper already holds is refused.
func (s *server) handlePlace(req *protocol.Request) {
	s.mu.Lock()
	_, held := s.places[req.ID]
	if !held {
		s.places[req.ID] = &place{whose: whoseOf(req)}
	}
	s.mu.Unlock()
	if held {
		s.log.Warn("place %s refused: the keeper already holds it", req.ID)
		s.send(protocol.NewError(req.ID, "", protocol.CodeBadRequest))
		return
	}
	s.send(protocol.NewPlaced(req.ID))
}

// handleDrop frees a place no spawn has named; a named one is freed with its
// spawn. It answers nothing.
func (s *server) handleDrop(req *protocol.Request) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if p := s.places[req.Place]; p != nil && !p.named {
		delete(s.places, req.Place)
	}
}

// handleAssign makes a place whose the request says, an athanor or a subject
// it does not name cleared. It answers nothing.
func (s *server) handleAssign(req *protocol.Request) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if p := s.places[req.Place]; p != nil {
		p.whose = whoseOf(req)
	}
}

// claimPlace has a starting spawn name its place: a place the keeper does not
// hold, or one another spawn named, cannot be.
func (s *server) claimPlace(id string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	p := s.places[id]
	if p == nil || p.named {
		return false
	}
	p.named = true
	return true
}

// handleMeasure answers whose a place is, its last reading and that
// reading's age, from what the reader stored: it never reads a group itself.
func (s *server) handleMeasure(req *protocol.Request) {
	var reply any = protocol.NewError(req.ID, "", protocol.CodeUnmeasured)
	s.mu.Lock()
	if p := s.places[req.Place]; p != nil && !p.readAt.IsZero() {
		reply = protocol.NewMeasured(req.ID, p.whose, p.reading, uint64(now().Sub(p.readAt).Milliseconds()))
	}
	s.mu.Unlock()
	s.send(reply)
}

// reader reads every live spawn's group each readEvery until stop closes.
func (s *server) reader(stop <-chan struct{}) {
	tick := time.NewTicker(readEvery)
	defer tick.Stop()
	for {
		select {
		case <-stop:
			return
		case <-tick.C:
			s.read()
		}
	}
}

// read reads every live spawn's group once, outside mu, so that a read
// however slow holds back no request, and stores each reading in its
// spawn's place only while that spawn is still held: a pooled spawn's group
// is named by its uid, which another spawn may take once this one is gone,
// and the place goes in the step its spawn leaves spawns. A read that fails
// leaves the last reading as it was.
func (s *server) read() {
	s.mu.Lock()
	live := make([]*spawn, 0, len(s.spawns))
	for _, sp := range s.spawns {
		live = append(live, sp)
	}
	s.mu.Unlock()
	for _, sp := range live {
		use, err := readUse(sp.group)
		if err != nil {
			continue
		}
		at := now()
		s.mu.Lock()
		if s.spawns[sp.id] == sp {
			p := s.places[sp.place]
			p.reading, p.readAt = protocol.Reading{Bytes: use.Bytes, Lesser: use.Lesser}, at
		}
		s.mu.Unlock()
	}
}
