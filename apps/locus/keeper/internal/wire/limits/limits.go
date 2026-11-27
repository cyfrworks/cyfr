// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package limits is Prima.Limits in Go, as a worker service reads it: the
// seven limits of one node of an attempt's authority, and the duration
// grammar they are written in. Prima's module is the one definition, and
// tests/fixtures/authority_wire.json holds this package to it.
package limits

import (
	"errors"
	"strings"

	"github.com/cyfr/locus/keeper/internal/wire/wirejson"
)

// Horizon is 2^53 − 1, the largest integer every JSON reader holds
// exactly: a duration's milliseconds are held to it on either side.
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
var Zero = Limits{
	Timeout: "30s", BatchTimeout: "30s", MaxMemoryBytes: 67_108_864,
	MaxRequestSize: 1_048_576, MaxResponseSize: 5_242_880, MaxConcurrentTasks: 1,
	RateLimit: RateLimit{Requests: 100, Window: "1m"},
}

// Duration reads text as Prima.Limits.parse_duration/1 does: an integer
// followed by one of ms, s, m or h, the suffixes tried in that order and
// exactly one taken off, or a bare integer of seconds; an integer is an
// optional sign and ASCII digits, of any size. It answers the
// milliseconds held to Horizon on either side, and false for text that is
// no duration.
func Duration(text string) (int64, bool) {
	number, unit := text, uint64(1000)
	for _, s := range []struct {
		suffix string
		unit   uint64
	}{{"ms", 1}, {"s", 1000}, {"m", 60_000}, {"h", 3_600_000}} {
		if strings.HasSuffix(text, s.suffix) {
			number, unit = strings.TrimSuffix(text, s.suffix), s.unit
			break
		}
	}
	negative := false
	if number != "" && (number[0] == '-' || number[0] == '+') {
		negative, number = number[0] == '-', number[1:]
	}
	if number == "" {
		return 0, false
	}
	for i := 0; i < len(number); i++ {
		if number[i] < '0' || number[i] > '9' {
			return 0, false
		}
	}
	significant := strings.TrimLeft(number, "0")
	magnitude := uint64(Horizon)
	if len(significant) <= 16 {
		var n uint64
		for i := 0; i < len(significant); i++ {
			n = n*10 + uint64(significant[i]-'0')
		}
		if n <= Horizon/unit {
			magnitude = n * unit
		}
		if magnitude > Horizon {
			magnitude = Horizon
		}
	}
	if negative {
		return -int64(magnitude), true
	}
	return int64(magnitude), true
}

// TimeoutMs is the node's timeout in milliseconds.
func (l Limits) TimeoutMs() int64 {
	ms, _ := Duration(l.Timeout)
	return ms
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
	duration := func(v any, positive bool) (string, bool) {
		s, isText := v.(string)
		if !isText {
			return "", false
		}
		ms, read := Duration(s)
		return s, read && ms >= 0 && (!positive || ms > 0)
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
