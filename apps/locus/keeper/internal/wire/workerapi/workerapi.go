// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package workerapi is Prima.WorkerAPI in Go, the worker service's side:
// what CYFR asks of a worker service (start, kill, status), how long CYFR
// waits for each and what it may do when an answer is lost, the status a
// worker service answers, and the words it holds for its keeper's
// refusals. Prima's module is the one definition and
// tests/fixtures/worker_api.json holds this package to it.
package workerapi

import (
	"errors"
	"regexp"
	"unicode/utf8"
)

// Callbacks are the WorkerAPI's callbacks, the one list of them
// (Prima.WorkerAPI.callbacks/0); every call answers a list of its own.
func Callbacks() []string { return []string{"start", "kill", "status"} }

// Retry is what CYFR may do when a callback's answer is lost: kill and
// status again, start never.
var Retry = map[string]string{"start": "never", "kill": "idempotent", "status": "idempotent"}

// TimeoutMs is how long CYFR waits for each callback's answer: the
// assignment's claim window for start, five seconds for kill and status.
var TimeoutMs = map[string]int{"start": 30_000, "kill": 5_000, "status": 5_000}

// RunnerStates are the states a status counts its runners in, each runner
// in exactly one.
var RunnerStates = []string{"fresh", "idle", "busy", "tainted"}

// MaxMessageBytes is the most bytes a refusal's sentence spans.
const MaxMessageBytes = 1024

// MaxMemoryBytes is the largest memory bound a status carries, 2^53 − 1.
const MaxMemoryBytes = 1<<53 - 1

var code = regexp.MustCompile(`\A[a-z][a-z0-9_]{0,63}\z`)

// Refusal is why a worker service's keeper refuses to start runners: a
// code and a sentence for the operator, and, for a place refused for room
// (no_memory), the keeper's held, what holds the memory, which a start
// refused for it answers and a status never carries.
type Refusal struct {
	Reason  string
	Message string
	Held    map[string]any
}

// Status is a worker service's state, as its status answer carries it.
type Status struct {
	Service     string
	Boot        string
	Runners     map[string]uint64
	Attempts    []string
	MemoryBytes uint64 // 0 for none
	Refusal     *Refusal
}

// ValidRefusalMessage is whether message is a sentence a refusal may
// carry: 1 to MaxMessageBytes bytes of UTF-8 without a control character.
func ValidRefusalMessage(message string) bool {
	if len(message) < 1 || len(message) > MaxMessageBytes || !utf8.ValidString(message) {
		return false
	}
	for i := 0; i < len(message); i++ {
		if message[i] < 0x20 || message[i] == 0x7f {
			return false
		}
	}
	return true
}

// ErrInvalid is a status Prima.WorkerAPI.status_to_wire/1 refuses.
var ErrInvalid = errors.New("invalid_status")

// Wire is the status as its JSON answer spells it, which CYFR reads
// (Prima.WorkerAPI.read_status/1): a plain map, which Prima writes with
// its members by name. A status Prima would not write is ErrInvalid: a
// count for other runner states than the four, a memory bound past
// 2^53 − 1, or a refusal whose reason is no code, whose sentence is not
// one a refusal carries, or that carries held.
func (s Status) Wire() (map[string]any, error) {
	if len(s.Runners) != len(RunnerStates) || s.MemoryBytes > MaxMemoryBytes {
		return nil, ErrInvalid
	}
	runners := map[string]any{}
	for _, state := range RunnerStates {
		n, counted := s.Runners[state]
		if !counted {
			return nil, ErrInvalid
		}
		runners[state] = n
	}
	attempts := make([]any, len(s.Attempts))
	for i, a := range s.Attempts {
		attempts[i] = a
	}
	var memory, refusal any
	if s.MemoryBytes > 0 {
		memory = s.MemoryBytes
	}
	if r := s.Refusal; r != nil {
		if !code.MatchString(r.Reason) || !ValidRefusalMessage(r.Message) || r.Held != nil {
			return nil, ErrInvalid
		}
		refusal = map[string]any{"reason": r.Reason, "message": r.Message}
	}
	return map[string]any{
		"service": s.Service, "boot": s.Boot, "runners": runners,
		"attempts": attempts, "memory_bytes": memory, "refusal": refusal,
	}, nil
}

// ReportRefusals are the codes of a keeper's refusal a worker service's
// report carries (Prima.WorkerAPI.runner_refusal/1 names a sentence of
// CYFR's for each); it carries no other.
var ReportRefusals = []string{"capacity", "memory_unavailable", "exec_failed", "guard_unavailable", "hosts_unresolved"}

// Reported is whether a report carries a refusal of code.
func Reported(c string) bool {
	for _, r := range ReportRefusals {
		if r == c {
			return true
		}
	}
	return false
}

// memoryUnavailable is the keeper's word for any bound it cannot enforce,
// the memory's or the CPU's.
const memoryUnavailable = "cyfr-locus cannot bound a runner's memory and CPU in this container, " +
	"so it starts none: start the locus service with the security " +
	"option writable-cgroups=true (Docker Engine 28 or later on a cgroup v2 " +
	"host whose memory and cpu controllers reach the container)"

// KeeperRefusal is the refusal a worker service holds for its keeper's
// refusal of a runner's spawn with code (Prima.WorkerAPI.keeper_refusal/1):
// memory_unavailable names what the deployment lacks; no_memory keeps the
// keeper's held beside it; any other code of a code's shape is named as it
// was sent, and anything else is refused.
func KeeperRefusal(c string, held map[string]any) Refusal {
	if c == "memory_unavailable" {
		return Refusal{Reason: c, Message: memoryUnavailable}
	}
	reason := "refused"
	if code.MatchString(c) {
		reason = c
	}
	r := Refusal{Reason: reason, Message: "cyfr-locus refused to start a runner (" + reason + ")"}
	if c == "no_memory" {
		r.Held = held
	}
	return r
}
