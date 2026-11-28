// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package hostapi is Prima.HostAPI in Go, as a worker service posts the
// host calls it makes and reads what CYFR answers: each callback's route,
// retry class and timeout, the bounds of a body and an answer, and what a
// call's caller makes of each try's answer (Locus.Runtime.HostClient's
// rule, which tests/fixtures/host_api.json's answer_outcomes hold).
// Prima's module is the one definition of the wire, and host_api.json
// holds this package to it.
package hostapi

import (
	"errors"
	"strings"
	"unicode"

	"github.com/cyfr/locus/keeper/internal/wire/macenvelope"
	"github.com/cyfr/locus/keeper/internal/wire/network"
	"github.com/cyfr/locus/keeper/internal/wire/pinned"
	"github.com/cyfr/locus/keeper/internal/wire/wirejson"
	"github.com/cyfr/locus/keeper/internal/wire/workerauth"
	"github.com/cyfr/locus/keeper/internal/wire/workerwire"
)

const (
	// MaxBodyBytes is the most a host call's body carries.
	MaxBodyBytes = workerwire.MaxBodyBytes
	// MaxAnswerBytes is the most a host call's answer carries.
	MaxAnswerBytes = 5_242_880
	// TimeoutMs is how long a caller waits for any callback's answer
	// before it counts it lost: the header window, so a late answer never
	// verifies as fresh.
	TimeoutMs = workerauth.WindowMs
	// FramesContentType is an admitted attached_fetch answer's content
	// type: its sealed frames.
	FramesContentType = "application/vnd.cyfr.frames"
	hostPrefix        = "/host/v1/"
)

// ErrUnknownCallback is a call of a callback the host API has not: it
// has no route and is never tried.
var ErrUnknownCallback = errors.New("unknown_callback")

// retries is what a caller may do when each callback's answer is lost:
// ask again (idempotent, outcome, batch, keyed) or never. Its names are
// the host API's callbacks.
var retries = map[string]string{
	"attach": "idempotent", "renew": "idempotent", "complete": "outcome", "fail": "outcome",
	"push_deltas": "batch", "oauth_token": "never", "take_rate": "never", "fetch_artifact": "idempotent",
	"storage": "never", "admit_child": "keyed", "tool_call": "never", "record_denial": "never",
	"release_child": "idempotent", "egress_pin": "idempotent", "attached_fetch": "never",
	"question_ask": "keyed", "question_wait": "idempotent", "runner_exited": "idempotent",
}

// Retries is each callback's retry class, a fresh map each call.
func Retries() map[string]string {
	out := make(map[string]string, len(retries))
	for callback, class := range retries {
		out[callback] = class
	}
	return out
}

// Route is the route a host call of callback is posted to on CYFR, and ok
// false for a callback the host API has not, which has none
// (Prima.WorkerWire.host_route/1 refuses its name).
func Route(callback string) (route string, ok bool) {
	if _, known := retries[callback]; !known {
		return "", false
	}
	return hostPrefix + callback, true
}

// Frames is whether an answer of these content-type values carries
// frames: one of them, cut at its first ; and trimmed of Unicode
// whitespace (Go's unicode.IsSpace and Elixir's String.trim/1 take the
// same set), is FramesContentType in any case, folded as Elixir's
// String.downcase/1 folds it.
func Frames(contentTypes []string) bool {
	for _, t := range contentTypes {
		t, _, _ = strings.Cut(t, ";")
		if network.Downcase(strings.TrimFunc(t, unicode.IsSpace)) == FramesContentType {
			return true
		}
	}
	return false
}

// Outcome is what a call came to. The zero Outcome is none of them: a
// Result no call made says nothing came of it.
type Outcome int

const (
	_ Outcome = iota
	// Answered is an answer CYFR gave, read at this version: the call's.
	Answered
	// Lost is a call whose effect is unknown, asked again where it may be.
	Lost
	// Uncertain is a call lost and never asked again.
	Uncertain
	// TooLarge is a call whose body is past the host's bound: refused
	// before it was read, never asked again.
	TooLarge
)

// Reading is what an answer says.
type Reading struct {
	// Kind is ok, refused, guest_error, setup_required or failed.
	Kind string
	// Value is ok's value; Name a refusal's.
	Value any
	Name  string
	// Type, Message and Remediation are a guest error's, Message a
	// failure's, Payload a setup's.
	Type, Message string
	Remediation   map[string]any
	Payload       map[string]any
}

// refusals are CYFR's refusals a call's answer is, besides a pin's for
// egress_pin.
var refusals = []string{"lost", "unavailable", "replayed", "malformed", "bad_mac", "claim_expired", "not_found"}

func named(name string, roster []string) bool {
	for _, r := range roster {
		if r == name {
			return true
		}
	}
	return false
}

// read is what an opened answer reads as for callback, or lost; final is
// an answer that says the host speaks another version, which is lost and
// never asked again.
func read(callback string, plain []byte) (r Reading, ok, final bool) {
	decoded, err := wirejson.Read(plain)
	if err != nil {
		return Reading{}, false, false
	}
	kind, value, name, fields := workerwire.ReadAnswer(decoded)
	switch kind {
	case workerwire.Answered:
		return Reading{Kind: "ok", Value: value}, true, false
	case workerwire.Lost:
		return Reading{}, false, false
	}
	switch name {
	case "setup_required":
		if payload, isObject := fields["payload"].(map[string]any); isObject {
			return Reading{Kind: "setup_required", Payload: payload}, true, false
		}
	case "guest_error":
		t, okType := fields["type"].(string)
		m, okMessage := fields["message"].(string)
		if okType && okMessage {
			remediation, _ := fields["remediation"].(map[string]any)
			return Reading{Kind: "guest_error", Type: t, Message: m, Remediation: remediation}, true, false
		}
	case "failed":
		if m, isText := fields["message"].(string); isText {
			return Reading{Kind: "failed", Message: m}, true, false
		}
	case "unknown_version":
		return Reading{}, false, true
	}
	if named(name, refusals) || (callback == "egress_pin" && named(name, pinned.Refusals())) {
		return Reading{Kind: "refused", Name: name}, true, false
	}
	return Reading{}, false, false
}

// Sent is what one try met: no answer at all (Arrived false: a transport's
// failure, an answer later than TimeoutMs, a 200 past MaxAnswerBytes), or
// a status and its body, a 200's sealed and any other's plain.
type Sent struct {
	Arrived bool
	Status  int
	Body    []byte
}

// Try is one try of a call: posted with a header and body sealed and signed
// afresh, its header's fields, and what it met.
type Try func() (call macenvelope.Message, sent Sent)

// Result is a call's outcome, its answer's reading, and how many times it
// was posted.
type Result struct {
	Outcome Outcome
	Reading Reading
	Posted  int
}

// Call makes a call of callback under the attempt's seal key: each try is
// posted, a 413 is TooLarge, a refusal that names unknown_version, plain
// at any version or sealed, is Lost, an answer read at this version is
// Answered, and anything else is lost: asked once more unless the
// callback's class is never, when the call is Uncertain at once; a second
// loss is Lost. A callback the host API has not is ErrUnknownCallback,
// before any try.
func Call(callback string, seal macenvelope.Key, try Try) (Result, error) {
	class, known := retries[callback]
	if !known {
		return Result{}, ErrUnknownCallback
	}
	posted := 0
	for {
		call, sent := try()
		posted++
		r, outcome, lost := meet(callback, seal, call, sent)
		if !lost {
			return Result{Outcome: outcome, Reading: r, Posted: posted}, nil
		}
		if class == "never" {
			return Result{Outcome: Uncertain, Posted: posted}, nil
		}
		if posted == 2 {
			return Result{Outcome: Lost, Posted: posted}, nil
		}
	}
}

// meet is what one try's answer comes to, or lost.
func meet(callback string, seal macenvelope.Key, call macenvelope.Message, sent Sent) (Reading, Outcome, bool) {
	switch {
	case !sent.Arrived:
		return Reading{}, 0, true
	case sent.Status == 413:
		return Reading{}, TooLarge, false
	case sent.Status != 200:
		if o, err := wirejson.Object(sent.Body); err == nil && o["error"] == "unknown_version" {
			return Reading{}, Lost, false
		}
		return Reading{}, 0, true
	}
	plain, err := workerauth.OpenCall(seal, workerauth.Answer, call, string(sent.Body))
	if err != nil {
		return Reading{}, 0, true
	}
	r, ok, final := read(callback, plain)
	switch {
	case final:
		return Reading{}, Lost, false
	case !ok:
		return Reading{}, 0, true
	}
	return r, Answered, false
}

// Bounded is an answer's body as a caller keeps it, read to max bytes:
// whole within the bound; past it, a 200 is no answer at all and any other
// status keeps its status with no body (Locus.Runtime.HostClient's
// post_call/5).
func Bounded(status int, body []byte, max int) Sent {
	switch {
	case len(body) <= max:
		return Sent{Arrived: true, Status: status, Body: body}
	case status == 200:
		return Sent{}
	default:
		return Sent{Arrived: true, Status: status, Body: []byte{}}
	}
}
