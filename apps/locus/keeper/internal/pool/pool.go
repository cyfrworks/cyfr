// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package pool tracks a contiguous range of uids lent to spawned processes.
// Each uid is free, in use by one spawn, or quarantined because a process
// under it outlived its retirement. Free uids are handed out in the order
// they became free, so a retired uid is the last to be reused.
//
// Pools have no classes: a build, an MCP backend and a runner (the
// long-lived process a worker service assigns executions to) draw uids
// from pools that behave alike. Every spawn runs under its uid with a
// private home, an environment built from nothing but its request, and
// resource limits, and is retired, its processes killed and its uid
// returned only once nothing it left remains, on release, on its leader's
// exit or on the loss of the client; no pool bounds a spawn's lifetime.
// The one thing a runner needs beyond that, its control channel on file
// descriptor 3, is asked for per spawn (`control` in package protocol), so
// a runner pool is whichever pool such spawns are drawn from.
//
// Every spawn runs in a space of its own: a user, network and IPC namespace
// the keeper makes for it. A pool declares the reach of its spaces
// (`<name>:<first>-<last>:<reach>`): ReachRelay, a runner's, whose one way
// to anything is its relay, or ReachRouted, a build's or a program's, whose
// one way out is the route its island's guard makes for it.
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

// A pool's reach.
const (
	// ReachRelay is a space with its loopback down and no route: the relay
	// its spawn inherits is its one way to anything.
	ReachRelay = "relay"
	// ReachRouted is a space with its loopback and one route, its island
	// guard's, and its names answered through that guard.
	ReachRouted = "routed"
)

// RouteLink is the name of a routed space's one link besides its loopback,
// the inner end of its guard's pair: the one link that comes up in the
// space. Its namespace holds only its loopback (and, on Docker Desktop,
// fallback tunnel devices, down and without an address) when the guard
// makes the pair.
const RouteLink = "eth0"

// Spec names a pool, its inclusive uid range and its spaces' reach.
type Spec struct {
	Name  string
	First int
	Last  int
	Reach string
}

// Routed reports whether the pool's spaces are routed.
func (s Spec) Routed() bool { return s.Reach == ReachRouted }

// ParseSpec parses `<name>:<first>-<last>:<reach>`, the reach ReachRelay or
// ReachRouted. The range must not include uid 0 and holds at most MaxSize
// uids.
func ParseSpec(s string) (Spec, error) {
	name, rest, ok := strings.Cut(s, ":")
	if !ok {
		return Spec{}, fmt.Errorf("pool %q: want <name>:<first>-<last>:<%s|%s>", s, ReachRelay, ReachRouted)
	}
	rng, reach, ok := strings.Cut(rest, ":")
	if !ok || (reach != ReachRelay && reach != ReachRouted) {
		return Spec{}, fmt.Errorf("pool %q: its reach must be %s or %s", s, ReachRelay, ReachRouted)
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
	return Spec{Name: name, First: first, Last: last, Reach: reach}, nil
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

// Stats reports a pool's size and its free and quarantined uids.
type Stats struct {
	Size        int
	Free        int
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

// Stats reports the pool's size and its free and quarantined uids.
func (p *Pool) Stats() Stats {
	st := Stats{Size: p.spec.Size(), Free: len(p.free)}
	for _, s := range p.state {
		if s == stateQuarantined {
			st.Quarantined++
		}
	}
	return st
}
