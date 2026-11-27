// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package admission

import "time"

// The pool's fixed numbers beside FloorBytes, each Prima.LocusPool's, which
// tests/fixtures/locus_pool.json carries to this package's test.
const (
	// FloorRunners is how many fresh runners the warm floor keeps.
	FloorRunners = 1
	// RoomWait is how long a start waits for room before it is refused:
	// the close's own wait (Prima.LocusBackends.close_wait_ms).
	RoomWait = 17 * time.Second
	// AllowanceFor is how long after its spawn a place is charged at least
	// its allowance; it is so charged from its place on.
	AllowanceFor = 10 * time.Second
	// StaleAfter is how long a place may go without a reading before it is
	// charged no less than its last charge.
	StaleAfter = 3 * time.Second
)

// Class is what a kind is charged and bounded as.
type Class int

// The classes: a runner (warm, run), a build, a session (program,
// terminal).
const (
	Runner Class = iota
	Build
	Session
)

// Kinds are every kind a place may be, with its class.
var Kinds = map[string]Class{
	"warm":     Runner,
	"run":      Runner,
	"build":    Build,
	"program":  Session,
	"terminal": Session,
}

// FloorKind says whether only the floor's role places the kind: a runner's.
func FloorKind(kind string) bool {
	c, ok := Kinds[kind]
	return ok && c == Runner
}

// Allowance is what a start of the class is charged at least for its first
// AllowanceFor, and the room it needs.
func Allowance(c Class) uint64 {
	switch c {
	case Runner:
		return FloorBytes
	case Build:
		return 800 << 20
	default:
		return 384 << 20
	}
}

// BuildCapBytes is a build's memory bound. A runner's and a session's is
// half of W, never under its least: a runner's its allowance and the
// components' hard ceiling together (Prima.Limits.Ceiling's 256 MiB), so a
// component at any cap an administrator may allow fits beside its runner;
// a session's its allowance.
const BuildCapBytes uint64 = 1 << 30

// LeastCapBytes is a runner's and a session's least memory bound.
var LeastCapBytes = map[Class]uint64{Runner: FloorBytes + 256<<20, Session: 384 << 20}

// Processors are each class's processors, its spawns' cpu.max.
var Processors = map[Class]uint64{Runner: 1, Build: 1, Session: 2}

// Limits are one spawn's bounds, which the keeper sets by its kind: its
// memory.max and its processors.
type Limits struct {
	MemoryBytes uint64
	Processors  uint64
}

// LimitsOf is the bounds of a spawn of the kind on a pool of work W.
func LimitsOf(kind string, work uint64) Limits {
	c := Kinds[kind]
	memory := BuildCapBytes
	if c != Build {
		memory = max(work/2, LeastCapBytes[c])
	}
	return Limits{MemoryBytes: memory, Processors: Processors[c]}
}

// MachineBytes is a person's VM's own allowance beside its first
// session's (Prima.LocusPool's machine_bytes): what a VM holds above a
// session's, the larger of the two figures V1 measured on the image's
// programs' device (325.6 MiB against today's steady state).
const MachineBytes uint64 = 326 << 20
