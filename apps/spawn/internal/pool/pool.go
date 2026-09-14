// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package pool tracks a contiguous range of uids lent to spawned processes.
// Each uid is free, in use by one spawn, or quarantined because a process
// under it outlived its retirement. Free uids are handed out in the order
// they became free, so a retired uid is the last to be reused.
//
// A Pool is not safe for concurrent use; its owner serializes access.
package pool

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

// MaxSize bounds the number of uids one pool may hold.
const MaxSize = 4096

var namePattern = regexp.MustCompile(`^[a-z][a-z0-9-]{0,31}$`)

// Spec names a pool and its inclusive uid range.
type Spec struct {
	Name  string
	First int
	Last  int
}

// ParseSpec parses `<name>:<first>-<last>`. The range must not include uid 0
// and holds at most MaxSize uids.
func ParseSpec(s string) (Spec, error) {
	name, rng, ok := strings.Cut(s, ":")
	if !ok {
		return Spec{}, fmt.Errorf("pool %q: want <name>:<first>-<last>", s)
	}
	if !namePattern.MatchString(name) {
		return Spec{}, fmt.Errorf("pool %q: name must match %s", s, namePattern)
	}
	lo, hi, ok := strings.Cut(rng, "-")
	if !ok {
		return Spec{}, fmt.Errorf("pool %q: want <first>-<last>", s)
	}
	first, err := parseUID(lo)
	if err != nil {
		return Spec{}, fmt.Errorf("pool %q: first uid: %w", s, err)
	}
	last, err := parseUID(hi)
	if err != nil {
		return Spec{}, fmt.Errorf("pool %q: last uid: %w", s, err)
	}
	if first > last {
		return Spec{}, fmt.Errorf("pool %q: first uid is above the last", s)
	}
	if last-first+1 > MaxSize {
		return Spec{}, fmt.Errorf("pool %q: more than %d uids", s, MaxSize)
	}
	return Spec{Name: name, First: first, Last: last}, nil
}

func parseUID(s string) (int, error) {
	if s == "" || strings.TrimLeft(s, "0123456789") != "" {
		return 0, fmt.Errorf("%q is not a decimal uid", s)
	}
	n, err := strconv.ParseUint(s, 10, 31)
	if err != nil {
		return 0, fmt.Errorf("%q is out of range", s)
	}
	if n == 0 {
		return 0, fmt.Errorf("uid 0 cannot be pooled")
	}
	return int(n), nil
}

// Size is the number of uids in the range.
func (s Spec) Size() int { return s.Last - s.First + 1 }

// Contains reports whether uid lies in the range.
func (s Spec) Contains(uid int) bool { return uid >= s.First && uid <= s.Last }

// Overlaps reports whether two ranges share a uid.
func (s Spec) Overlaps(o Spec) bool { return s.First <= o.Last && o.First <= s.Last }

type state int

const (
	stateFree state = iota
	stateInUse
	stateQuarantined
)

// Stats counts a pool's uids by state.
type Stats struct {
	Size        int
	Free        int
	InUse       int
	Quarantined int
}

// Pool is the allocation state of one Spec.
type Pool struct {
	spec  Spec
	free  []int
	state map[int]state
}

// New returns a pool with every uid free, in ascending order.
func New(spec Spec) *Pool {
	p := &Pool{spec: spec, state: make(map[int]state, spec.Size())}
	for uid := spec.First; uid <= spec.Last; uid++ {
		p.free = append(p.free, uid)
		p.state[uid] = stateFree
	}
	return p
}

// Spec returns the pool's name and range.
func (p *Pool) Spec() Spec { return p.spec }

// Allocate takes the longest-free uid and marks it in use. A candidate for
// which busy reports true is quarantined instead and the next is tried.
// It reports false when no free uid remains.
func (p *Pool) Allocate(busy func(uid int) bool) (int, bool) {
	for len(p.free) > 0 {
		uid := p.free[0]
		p.free = p.free[1:]
		if busy != nil && busy(uid) {
			p.state[uid] = stateQuarantined
			continue
		}
		p.state[uid] = stateInUse
		return uid, true
	}
	return 0, false
}

// Release returns an in-use or quarantined uid to the back of the free list.
func (p *Pool) Release(uid int) error {
	switch st, ok := p.state[uid]; {
	case !ok:
		return fmt.Errorf("uid %d is not in pool %s", uid, p.spec.Name)
	case st == stateFree:
		return fmt.Errorf("uid %d is already free", uid)
	}
	p.state[uid] = stateFree
	p.free = append(p.free, uid)
	return nil
}

// Quarantine withholds an in-use uid from allocation until it is released.
func (p *Pool) Quarantine(uid int) error {
	switch st, ok := p.state[uid]; {
	case !ok:
		return fmt.Errorf("uid %d is not in pool %s", uid, p.spec.Name)
	case st != stateInUse:
		return fmt.Errorf("uid %d is not in use", uid)
	}
	p.state[uid] = stateQuarantined
	return nil
}

// Quarantined lists the quarantined uids in ascending order.
func (p *Pool) Quarantined() []int {
	var out []int
	for uid := p.spec.First; uid <= p.spec.Last; uid++ {
		if p.state[uid] == stateQuarantined {
			out = append(out, uid)
		}
	}
	return out
}

// Stats counts the pool's uids by state.
func (p *Pool) Stats() Stats {
	st := Stats{Size: p.spec.Size(), Free: len(p.free)}
	for _, s := range p.state {
		switch s {
		case stateInUse:
			st.InUse++
		case stateQuarantined:
			st.Quarantined++
		}
	}
	return st
}
