// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package admission holds the pool's numbers: one memory bound for all a
// machine's Locus work, W, and within it rest, which leaves the warm
// floor its memory (package cgroup's tree). Their one definition is
// Prima.LocusPool's, which tests/fixtures/locus_pool.json carries to this
// package's test.
package admission

// FloorBytes is F, the memory the warm floor keeps from builds and
// programs: its one runner's allowance.
const FloorBytes uint64 = 164 << 20

// Sizes are the pool's bounds on one machine.
type Sizes struct {
	// Budget is MemTotal less the reserve, never below 0, or the
	// container's own limit where that is less.
	Budget uint64
	// Work is W, the budget less the services' share, never below 0.
	Work uint64
	// Rest is W less F where a floor is kept, never below 0, else W.
	Rest uint64
}

// Size is the sizing rule: memTotal the machine's, limit the container's
// own (limited false where it has none), reserve and share the two
// settings, and floor whether a role keeps the warm floor.
func Size(memTotal, limit uint64, limited bool, reserve, share uint64, floor bool) Sizes {
	budget := sub(memTotal, reserve)
	if limited {
		budget = min(budget, limit)
	}
	work := sub(budget, share)
	rest := work
	if floor {
		rest = sub(work, FloorBytes)
	}
	return Sizes{Budget: budget, Work: work, Rest: rest}
}

func sub(a, b uint64) uint64 {
	if a < b {
		return 0
	}
	return a - b
}
