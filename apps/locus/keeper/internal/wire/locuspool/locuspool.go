// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package locuspool is Prima.LocusPool's pool wire in Go, as the runtime
// service serves it: the route every Locus service answers its role's
// report on, CYFR's signed request, the report the role's keeper gives,
// and the answer written for CYFR. Prima's module is the one definition,
// and tests/fixtures/locus_pool.json's wire holds this package to it.
//
// A request is POST Route, its body {"v": 1, "after": rev} within
// MaxRequestBytes, signed in macenvelope.AuthHeader as Prima.MacEnvelope
// signs: the prefix cyfr-locus/v1/<service>/pool, the kind pool, the field
// ts within WindowMs of the listener's clock, and the body's hash, under
// the service's pool key, derived over the same label from the key the
// service holds. No nonce is kept: the call reads only. The answer is
// {"v": 1, "report": report}, plain.
package locuspool

import (
	"errors"
	"regexp"
	"time"

	"github.com/cyfr/locus/keeper/internal/wire/macenvelope"
	"github.com/cyfr/locus/keeper/internal/wire/wirejson"
)

const (
	// Version is the pool wire's version, every body's and answer's v.
	Version = 1
	// Route is the pool wire's one route, on each service.
	Route = "/locus/v1/pool"
	// MaxRequestBytes is the most bytes a request body may be.
	MaxRequestBytes = 1024
	// ReportCounters is the most counters one report carries.
	ReportCounters = 256
	// WindowMs is how far a header's ts may be from the listener's clock,
	// either side; at WindowMs it verifies.
	WindowMs = 30_000
)

var (
	// ErrOutsideWindow is a header whose ts is past WindowMs from the
	// clock.
	ErrOutsideWindow = errors.New("outside_window")
	// ErrBadMAC is a header whose MAC is not the service's pool key's, or
	// a body that is not the one its header hashed.
	ErrBadMAC = errors.New("bad_mac")
	// ErrVersion is a request body at another version, or at none: read
	// before anything else of it.
	ErrVersion = errors.New("version")
	// ErrMalformed is a request body, a report or a counter that does
	// not read.
	ErrMalformed = errors.New("malformed")
	// ErrUnknownService is a service that serves no pool wire.
	ErrUnknownService = errors.New("unknown_service")
)

// Services are the services that serve the pool wire, a fresh list each
// call.
func Services() []string { return []string{"runtime", "builds", "backends"} }

func known(service string) bool {
	for _, s := range Services() {
		if s == service {
			return true
		}
	}
	return false
}

func envelope(service string) macenvelope.Envelope {
	return macenvelope.Envelope{
		Prefix: macenvelope.Label(service) + "/pool",
		Kind:   "pool",
		Fields: []macenvelope.Field{{Name: "ts", Type: macenvelope.Integer}},
	}
}

// HeldPoolKey is service's pool key, derived from the key that service
// holds over its pool label (Prima.LocusPool.held_pool_key/2): a worker
// service's own key, for the runtime.
func HeldPoolKey(service string, held macenvelope.Key) (macenvelope.Key, error) {
	if !known(service) {
		return macenvelope.Key{}, ErrUnknownService
	}
	return macenvelope.Derive(held, envelope(service).Prefix), nil
}

// VerifyHeader is the body hash a request's header names, once the header
// is a v1 header of service's pool envelope, its ts within WindowMs of now
// (Unix ms) and its MAC that of poolKey; otherwise the first of
// macenvelope.ErrUnknownVersion, macenvelope.ErrMalformed,
// ErrOutsideWindow and ErrBadMAC. The zero Key verifies nothing.
func VerifyHeader(service string, poolKey macenvelope.Key, header string, now int64) (string, error) {
	if !known(service) {
		return "", ErrUnknownService
	}
	e := envelope(service)
	p, err := e.Parse(header)
	if err != nil {
		return "", err
	}
	if d := int64(p.Message["ts"].(uint64)) - now; d < -WindowMs || d > WindowMs {
		return "", ErrOutsideWindow
	}
	if !e.VerifyHeader(poolKey, p.Message, p.BodyHash, p.MAC) {
		return "", ErrBadMAC
	}
	return p.BodyHash, nil
}

// VerifyBody is nil when body is the one a verified header hashed, and
// ErrBadMAC otherwise.
func VerifyBody(bodyHash string, body []byte) error {
	if !macenvelope.VerifyBody(bodyHash, body) {
		return ErrBadMAC
	}
	return nil
}

// ReadRequestBody is the rev a request's body asks after: an object of
// exactly v and after, after a whole number from 0 to 2^53 − 1. An object
// at another version, or at none, is ErrVersion before anything else is
// read; anything else, an object whose v is 1 among it, is ErrMalformed.
func ReadRequestBody(body []byte) (uint64, error) {
	v, err := wirejson.Read(body)
	if err != nil {
		return 0, ErrMalformed
	}
	o, ok := v.(map[string]any)
	if !ok {
		return 0, ErrMalformed
	}
	if version, isInteger := wirejson.Uint(o["v"], Version); !isInteger || version != Version {
		return 0, ErrVersion
	}
	rev, isRev := wirejson.Uint(o["after"], wirejson.MaxSafeInteger)
	if len(o) != 2 || !isRev {
		return 0, ErrMalformed
	}
	return rev, nil
}

// Counter is one counter of a report: its rev, its UTC day, its kind,
// its athanor and subject where it has them, and its numbers.
type Counter struct {
	Rev, Bytes, MibMs, MeasuredMs, PeakBytes, Cap, Machine, Either uint64
	// Day is the counter's UTC day, YYYY-MM-DD.
	Day string
	// Kind is a place's kind (Prima.LocusPool.kinds/0).
	Kind string
	// Athanor and Subject are none when empty.
	Athanor, Subject string
}

// Report is a role's report: its keeper's boot, its budget, work, floor
// and use, up to ReportCounters counters in ascending rev, and the rev
// the next page follows, when more follow (0 for none).
type Report struct {
	Boot                      string
	Budget, Work, Floor, Used uint64
	Counters                  []Counter
	Next                      uint64
}

var (
	boot = regexp.MustCompile(`\A[0-9a-f]{32}\z`)
	// athanor is an athanor id's grammar on every Locus wire, 1 to 256 bytes
	// of printable ASCII without spaces (Prima.RunnerControl.athanor_id_pattern/0).
	athanor = regexp.MustCompile(`\A[\x21-\x7e]{1,256}\z`)
	// subject is the keeper's id grammar (Prima.KeeperProtocol.id?/1).
	subject = regexp.MustCompile(`\A[A-Za-z0-9._:-]{1,64}\z`)
	kinds   = map[string]bool{"warm": true, "run": true, "build": true, "program": true, "terminal": true}
	numbers = []string{"rev", "bytes", "mib_ms", "measured_ms", "peak_bytes", "cap", "machine", "either"}
	members = []string{"boot", "budget", "work", "floor", "used", "counters"}
)

func whole(v any) (uint64, bool) { return wirejson.Uint(v, wirejson.MaxSafeInteger) }

// ReadReport reads a report from its wire form strictly
// (Prima.LocusPool.read_report/1): exactly its members, next only where
// more follow; every number a whole number from 0 to 2^53 − 1, a rev and
// next from 1; boot 32 lowercase hexadecimal digits; at most
// ReportCounters counters in ascending rev, each exactly its members, its
// day a date, its kind a place's kind, an athanor and a subject of their
// grammars where present; none null.
func ReadReport(v any) (Report, error) {
	o, ok := v.(map[string]any)
	if !ok {
		return Report{}, ErrMalformed
	}
	want := len(members)
	if _, more := o["next"]; more {
		want++
	}
	if len(o) != want {
		return Report{}, ErrMalformed
	}
	var r Report
	var okBoot, okBudget, okWork, okFloor, okUsed bool
	r.Boot, okBoot = o["boot"].(string)
	r.Budget, okBudget = whole(o["budget"])
	r.Work, okWork = whole(o["work"])
	r.Floor, okFloor = whole(o["floor"])
	r.Used, okUsed = whole(o["used"])
	if !(okBoot && boot.MatchString(r.Boot) && okBudget && okWork && okFloor && okUsed) {
		return Report{}, ErrMalformed
	}
	if next, more := o["next"]; more {
		n, isRev := whole(next)
		if !isRev || n < 1 {
			return Report{}, ErrMalformed
		}
		r.Next = n
	}
	counters, isList := o["counters"].([]any)
	if !isList || len(counters) > ReportCounters {
		return Report{}, ErrMalformed
	}
	for _, item := range counters {
		c, err := readCounter(item)
		if err != nil || (len(r.Counters) > 0 && c.Rev <= r.Counters[len(r.Counters)-1].Rev) {
			return Report{}, ErrMalformed
		}
		r.Counters = append(r.Counters, c)
	}
	return r, nil
}

func readCounter(v any) (Counter, error) {
	o, ok := v.(map[string]any)
	if !ok {
		return Counter{}, ErrMalformed
	}
	want := len(numbers) + 2
	for _, optional := range []string{"athanor", "subject"} {
		if _, has := o[optional]; has {
			want++
		}
	}
	if len(o) != want {
		return Counter{}, ErrMalformed
	}
	read := map[string]uint64{}
	for _, n := range numbers {
		value, isWhole := whole(o[n])
		if !isWhole {
			return Counter{}, ErrMalformed
		}
		read[n] = value
	}
	c := Counter{Rev: read["rev"], Bytes: read["bytes"], MibMs: read["mib_ms"], MeasuredMs: read["measured_ms"],
		PeakBytes: read["peak_bytes"], Cap: read["cap"], Machine: read["machine"], Either: read["either"]}
	var okDay, okKind bool
	c.Day, okDay = o["day"].(string)
	c.Kind, okKind = o["kind"].(string)
	if c.Rev < 1 || !okDay || !isDay(c.Day) || !okKind || !kinds[c.Kind] {
		return Counter{}, ErrMalformed
	}
	for name, field := range map[string]*string{"athanor": &c.Athanor, "subject": &c.Subject} {
		value, has := o[name]
		if !has {
			continue
		}
		text, isText := value.(string)
		grammar := athanor
		if name == "subject" {
			grammar = subject
		}
		if !isText || !grammar.MatchString(text) {
			return Counter{}, ErrMalformed
		}
		*field = text
	}
	return c, nil
}

// isDay is whether text is a date as Date.from_iso8601/1 reads ten
// characters: YYYY-MM-DD, a day of its month.
func isDay(text string) bool {
	if len(text) != 10 {
		return false
	}
	d, err := time.Parse("2006-01-02", text)
	return err == nil && d.Format("2006-01-02") == text
}

// Answer is the answer carrying r (Prima.LocusPool.answer/1): v, then the
// report, its members by name, next only where more follow, each counter's
// athanor and subject only where it has them. A report of more than
// ReportCounters counters is ErrMalformed: no answer carries one.
func Answer(r Report) ([]byte, error) {
	if len(r.Counters) > ReportCounters {
		return nil, ErrMalformed
	}
	counters := make([]any, len(r.Counters))
	for i, c := range r.Counters {
		m := map[string]any{
			"rev": c.Rev, "bytes": c.Bytes, "mib_ms": c.MibMs, "measured_ms": c.MeasuredMs,
			"peak_bytes": c.PeakBytes, "cap": c.Cap, "machine": c.Machine, "either": c.Either,
			"day": c.Day, "kind": c.Kind,
		}
		if c.Athanor != "" {
			m["athanor"] = c.Athanor
		}
		if c.Subject != "" {
			m["subject"] = c.Subject
		}
		counters[i] = m
	}
	report := map[string]any{
		"boot": r.Boot, "budget": r.Budget, "work": r.Work, "floor": r.Floor, "used": r.Used, "counters": counters,
	}
	if r.Next != 0 {
		report["next"] = r.Next
	}
	return wirejson.Write(wirejson.Ordered{{Name: "v", Value: Version}, {Name: "report", Value: report}})
}

// Refusal is why the pool route refused a request (Locus.PoolRoute): a
// header, Unauthorized, and its reason; a body past MaxRequestBytes,
// TooLarge; a body that does not read, BadBody, and ErrVersion or
// ErrMalformed; a keeper that does not answer, Unavailable.
type Refusal struct {
	Stage  Stage
	Reason error
}

// Stage is where a pool request was refused.
type Stage int

const (
	_ Stage = iota
	// Unauthorized is the header's refusal, or the body's against its hash.
	Unauthorized
	// TooLarge is a body past MaxRequestBytes.
	TooLarge
	// BadBody is a body that does not read as a request.
	BadBody
	// Unavailable is a keeper that does not answer, or refuses.
	Unavailable
)

// Status is the HTTP status and error a worker service answers a pool
// refusal with, in its WorkerWire words (Locus.Runtime.WorkerListener):
// a header's refusal 401 and its reason, a body past the bound 413
// malformed, a body at another version 400 unknown_version and any other
// 400 malformed, a keeper's 503 unavailable. A Refusal no route made has
// none (ok false).
func (r Refusal) Status() (status int, code string, ok bool) {
	switch r.Stage {
	case Unauthorized:
		for _, e := range []error{macenvelope.ErrUnknownVersion, macenvelope.ErrMalformed, ErrOutsideWindow, ErrBadMAC} {
			if errors.Is(r.Reason, e) {
				return 401, e.Error(), true
			}
		}
	case TooLarge:
		return 413, "malformed", true
	case BadBody:
		switch {
		case errors.Is(r.Reason, ErrVersion):
			return 400, "unknown_version", true
		case errors.Is(r.Reason, ErrMalformed):
			return 400, "malformed", true
		}
	case Unavailable:
		return 503, "unavailable", true
	}
	return 0, "", false
}
