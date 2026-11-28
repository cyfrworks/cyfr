// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package limits is Prima.Limits in Go, as a worker service reads it: the
// seven limits of one node of an attempt's authority, and the duration
// grammar they are written in. Prima's module is the one definition, and
// tests/fixtures/authority_wire.json holds this package to it.
package limits

import (
	"errors"
	"math"
	"strconv"
	"strings"

	"github.com/cyfr/locus/keeper/internal/wire/wirejson"
)

// Horizon is 2^53 − 1, the largest integer every JSON reader holds
// exactly: the most a count of a node's limits is.
const Horizon = wirejson.MaxSafeInteger

// ErrRefused is limits Prima.Limits.new/1 refuses.
var ErrRefused = errors.New("invalid_limit")

// Limits are a node's limits.
type Limits struct {
	Timeout            string
	BatchTimeout       string
	MaxMemoryBytes     uint64
	MaxRequestSize     uint64
	MaxResponseSize    uint64
	MaxConcurrentTasks uint64
	RateLimit          RateLimit
}

// RateLimit is a node's rate limit.
type RateLimit struct {
	Requests uint64
	Window   string
}

// Zero is the limits of an unbound authority (Prima.Authority's zero
// limits).
func Zero() Limits { return zero }

var zero = Limits{
	Timeout: "30s", BatchTimeout: "30s", MaxMemoryBytes: 67_108_864,
	MaxRequestSize: 1_048_576, MaxResponseSize: 5_242_880, MaxConcurrentTasks: 1,
	RateLimit: RateLimit{Requests: 100, Window: "1m"},
}

// units are a duration's suffixes, tried in this order, and the
// milliseconds of each.
var units = []struct {
	suffix string
	unit   uint64
}{{"ms", 1}, {"s", 1000}, {"m", 60_000}, {"h", 3_600_000}}

// grammar reads text as Prima.Limits.parse_duration/1 reads it: an
// integer followed by one of ms, s, m or h, the suffixes tried in that
// order and exactly one taken off, or a bare integer of seconds; an
// integer is an optional sign and ASCII digits, of any size. It answers
// the sign, the digits without leading zeros ("" for zero) and the unit's
// milliseconds, and false for text that is no duration.
func grammar(text string) (negative bool, digits string, unit uint64, ok bool) {
	number, unit := text, uint64(1000)
	for _, u := range units {
		if strings.HasSuffix(text, u.suffix) {
			number, unit = strings.TrimSuffix(text, u.suffix), u.unit
			break
		}
	}
	if number != "" && (number[0] == '-' || number[0] == '+') {
		negative, number = number[0] == '-', number[1:]
	}
	if number == "" {
		return false, "", 0, false
	}
	for i := 0; i < len(number); i++ {
		if number[i] < '0' || number[i] > '9' {
			return false, "", 0, false
		}
	}
	return negative, strings.TrimLeft(number, "0"), unit, true
}

// Duration is the milliseconds text spells, as
// Prima.Limits.parse_duration/1 answers them, and false for text that is
// no duration. Prima answers an integer of any size; Go holds an int64,
// so a duration past it is false here: the one difference,
// authority_wire.json's durations marked go.
func Duration(text string) (int64, bool) {
	negative, digits, unit, ok := grammar(text)
	if !ok {
		return 0, false
	}
	var n uint64
	if digits != "" {
		parsed, err := strconv.ParseUint(digits, 10, 64)
		if err != nil {
			return 0, false
		}
		n = parsed
	}
	if n > math.MaxInt64/unit {
		return 0, false
	}
	if negative {
		return -int64(n * unit), true
	}
	return int64(n * unit), true
}

var members = []string{"timeout", "batch_timeout", "max_memory_bytes", "max_request_size",
	"max_response_size", "max_concurrent_tasks", "rate_limit"}

// Read reads a node's limits as Prima.Limits.new/1 reads a JSON object of
// them: exactly the seven members; each count an integer from 0 to 2^53 −
// 1; each duration one Duration reads, not below zero; and a rate limit of
// exactly its requests, a count, and its window, a duration above zero.
func Read(v any) (Limits, error) {
	o, ok := v.(map[string]any)
	if !ok || len(o) != len(members) {
		return Limits{}, ErrRefused
	}
	for _, m := range members {
		if _, has := o[m]; !has {
			return Limits{}, ErrRefused
		}
	}
	count := func(v any) (uint64, bool) { return wirejson.Uint(v, Horizon) }
	// A duration of any size reads, as Prima reads it: its grammar and
	// sign decide, not whether its milliseconds fit an int64.
	duration := func(v any, positive bool) (string, bool) {
		s, isText := v.(string)
		if !isText {
			return "", false
		}
		negative, digits, _, read := grammar(s)
		return s, read && (!negative || digits == "") && (!positive || digits != "")
	}
	var l Limits
	var okT, okB, okM, okQ, okR, okC bool
	l.Timeout, okT = duration(o["timeout"], false)
	l.BatchTimeout, okB = duration(o["batch_timeout"], false)
	l.MaxMemoryBytes, okM = count(o["max_memory_bytes"])
	l.MaxRequestSize, okQ = count(o["max_request_size"])
	l.MaxResponseSize, okR = count(o["max_response_size"])
	l.MaxConcurrentTasks, okC = count(o["max_concurrent_tasks"])
	if !(okT && okB && okM && okQ && okR && okC) {
		return Limits{}, ErrRefused
	}
	rate, isObject := o["rate_limit"].(map[string]any)
	if !isObject || len(rate) != 2 {
		return Limits{}, ErrRefused
	}
	requests, okReq := count(rate["requests"])
	window, okWin := duration(rate["window"], true)
	if !okReq || !okWin {
		return Limits{}, ErrRefused
	}
	l.RateLimit = RateLimit{Requests: requests, Window: window}
	return l, nil
}
