// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package workerauth is Prima.WorkerAuth in Go, the worker service's side:
// how CYFR and a worker service authenticate each other and how an
// attempt's host calls are signed and sealed, spelled with package
// macenvelope. Prima's module is the one definition and
// tests/fixtures/worker_auth.json holds this package to it.
//
// The keys, each derived, none stored:
//
//	WorkerKey(root, service)        cyfr-locus/v1/runtime and the service's id
//	DispatchKey(worker key)         signs WorkerAPI requests and the service's reports
//	DispatchSealKey(worker key)     seals the keys of an attempt started on the service
//	AttemptCallKey(root, attempt)   signs the attempt's host calls
//	AttemptSealKey(root, attempt)   seals the attempt's host call bodies and answers
//
// A worker service holds its dispatch keys and, for each attempt it
// started, the attempt's two keys, opened from what CYFR sealed for it
// (OpenAttemptKeys). It verifies CYFR's requests (VerifyRequestHeader),
// signs its reports (ReportHeader), and verifies a host call its runner
// hands it under the attempt's call key before it posts the call
// (VerifyHostCallHeaderUnder). Each verifier reads the header alone, so a
// listener refuses an unauthenticated caller before it reads the body,
// and answers the first refusal in this order: ErrUnknownVersion,
// ErrMalformed, ErrOutsideWindow (a timestamp more than WindowMs from the
// clock, either side; at WindowMs it verifies), ErrBadMAC. VerifyBody
// then checks the body read afterwards against the hash the header named.
package workerauth

import (
	"errors"
	"strings"

	"github.com/cyfr/locus/keeper/internal/wire/macenvelope"
	"github.com/cyfr/locus/keeper/internal/wire/wirejson"
)

// WindowMs is how far a header's ts may be from the verifier's clock, in
// milliseconds, on either side.
const WindowMs = 30_000

var (
	ErrUnknownVersion = macenvelope.ErrUnknownVersion
	ErrMalformed      = macenvelope.ErrMalformed
	ErrOutsideWindow  = errors.New("outside_window")
	ErrBadMAC         = errors.New("bad_mac")
	ErrUnsealable     = macenvelope.ErrUnsealable
)

var label = macenvelope.Label("runtime")

// AttemptFields are an attempt's six fields, in their order.
var AttemptFields = []macenvelope.Field{
	{Name: "athanor_id", Type: macenvelope.String},
	{Name: "execution_id", Type: macenvelope.String},
	{Name: "attempt", Type: macenvelope.String},
	{Name: "fence", Type: macenvelope.Integer},
	{Name: "generation", Type: macenvelope.Integer},
	{Name: "service", Type: macenvelope.String},
}

// Call is a host call's envelope: the attempt's fields, the boot and the
// runner presenting it, the member it is addressed to, ts and a nonce.
var Call = macenvelope.Envelope{Prefix: label, Kind: "call", Fields: append(append([]macenvelope.Field{}, AttemptFields...),
	macenvelope.Field{Name: "boot", Type: macenvelope.String},
	macenvelope.Field{Name: "runner", Type: macenvelope.String},
	macenvelope.Field{Name: "member", Type: macenvelope.String},
	macenvelope.Field{Name: "ts", Type: macenvelope.Integer},
	macenvelope.Field{Name: "nonce", Type: macenvelope.String},
)}

var dispatchFields = []macenvelope.Field{
	{Name: "service", Type: macenvelope.String},
	{Name: "boot", Type: macenvelope.String},
	{Name: "ts", Type: macenvelope.Integer},
	{Name: "nonce", Type: macenvelope.String},
}

// Request and Report are a WorkerAPI request's envelope and a worker
// service report's; the two never verify as each other.
var (
	Request = macenvelope.Envelope{Prefix: label, Kind: "request", Fields: dispatchFields}
	Report  = macenvelope.Envelope{Prefix: label, Kind: "report", Fields: dispatchFields}
)

// MaxCallHeaderBytes is the most bytes a host call's header spans with a
// MAC an HMAC-SHA256 can be (43 characters), Prima's
// max_host_call_header_bytes/0.
var MaxCallHeaderBytes = Call.MaxHeaderBytes() - macenvelope.MaxText + 43

// AssignKey is the key assignments are MAC'd with; only CYFR holds it.
func AssignKey(root macenvelope.Key) macenvelope.Key {
	return macenvelope.Derive(root, label+"/assign")
}

// WorkerKey is the key of the worker service service, derived over its
// stable id, never its boot.
func WorkerKey(root macenvelope.Key, service string) (macenvelope.Key, error) {
	return macenvelope.DeriveFields(root, label, dispatchFields[:1], macenvelope.Message{"service": service})
}

// DispatchKey signs WorkerAPI requests to a worker service and its reports.
func DispatchKey(worker macenvelope.Key) macenvelope.Key {
	return macenvelope.Derive(worker, label+"/dispatch")
}

// DispatchSealKey seals the attempt keys a worker service is started with.
func DispatchSealKey(worker macenvelope.Key) macenvelope.Key {
	return macenvelope.Derive(worker, label+"/dseal")
}

// AttemptCallKey is the key an attempt's runner signs its host calls with.
func AttemptCallKey(root macenvelope.Key, attempt macenvelope.Message) (macenvelope.Key, error) {
	return macenvelope.DeriveFields(root, label+"/call", AttemptFields, attempt)
}

// AttemptSealKey is the key an attempt's host call bodies and answers are
// sealed with.
func AttemptSealKey(root macenvelope.Key, attempt macenvelope.Message) (macenvelope.Key, error) {
	return macenvelope.DeriveFields(root, label+"/seal", AttemptFields, attempt)
}

// AttemptKeys are an attempt and the two keys of it a worker service
// holds; they print as their attempt and two redacted keys.
type AttemptKeys struct {
	Attempt macenvelope.Message
	Call    macenvelope.Key
	Seal    macenvelope.Key
}

const attemptKeysLabel = "cyfr-locus/v1/runtime/attempt-keys"

// OpenAttemptKeys opens what CYFR sealed for this worker service with its
// dispatch seal key: base64url(attempt) "." sealed, attempt being a JSON
// object of exactly the six attempt fields, each of its type, and sealed
// the call key then the seal key, 32 bytes each, sealed to the attempt it
// names. Anything else is ErrUnsealable.
func OpenAttemptKeys(sealKey macenvelope.Key, sealed string) (AttemptKeys, error) {
	named, box, found := strings.Cut(sealed, ".")
	if !found || strings.Contains(box, ".") {
		return AttemptKeys{}, ErrUnsealable
	}
	attempt, ok := readAttempt(named)
	if !ok {
		return AttemptKeys{}, ErrUnsealable
	}
	plain, err := macenvelope.Open(sealKey, attemptKeysLabel, AttemptFields, attempt, box)
	if err != nil || len(plain) != 64 {
		return AttemptKeys{}, ErrUnsealable
	}
	call, _ := macenvelope.KeyFromBytes(plain[:32])
	seal, _ := macenvelope.KeyFromBytes(plain[32:])
	clear(plain)
	return AttemptKeys{Attempt: attempt, Call: call, Seal: seal}, nil
}

// readAttempt is the attempt sealed keys name: exactly its six fields,
// each of its type. Their values are held to the field rules where the
// seal is opened under them.
func readAttempt(named string) (macenvelope.Message, bool) {
	raw, ok := macenvelope.DecodeURL(named)
	if !ok {
		return nil, false
	}
	wire, err := wirejson.Object(raw)
	if err != nil || len(wire) != len(AttemptFields) {
		return nil, false
	}
	attempt := make(macenvelope.Message, len(AttemptFields))
	for _, f := range AttemptFields {
		v, given := wire[f.Name]
		if !given {
			return nil, false
		}
		switch f.Type {
		case macenvelope.String:
			s, isString := v.(string)
			if !isString {
				return nil, false
			}
			attempt[f.Name] = s
		case macenvelope.Integer:
			if !wirejson.IsInteger(v) {
				return nil, false
			}
			// An integer the field takes no value of, of any size, is held
			// as one past the field's range, so the seal does not open.
			n, inRange := wirejson.Uint(v, macenvelope.MaxInteger)
			if !inRange {
				n = macenvelope.MaxInteger + 1
			}
			attempt[f.Name] = n
		}
	}
	return attempt, true
}

// Direction is which half of a host call a sealed value is.
type Direction string

const (
	Body   Direction = "body"
	Answer Direction = "answer"
)

func (d Direction) label() (string, bool) {
	switch d {
	case Body:
		return "cyfr-locus/v1/runtime/call-body", true
	case Answer:
		return "cyfr-locus/v1/runtime/call-answer", true
	}
	return "", false
}

// SealedBytes is the bytes SealCall writes for a plaintext of n bytes.
func SealedBytes(n int) int {
	raw := 28 + n
	tail := [3]int{0, 2, 3}[raw%3]
	return raw/3*4 + tail
}

// SealCall seals one half of a host call with the attempt's seal key,
// bound to the call's header fields.
func SealCall(sealKey macenvelope.Key, d Direction, call macenvelope.Message, plaintext, iv []byte) (string, error) {
	l, ok := d.label()
	if !ok {
		return "", errors.New("no such direction")
	}
	return macenvelope.Seal(sealKey, l, Call.Fields, call, plaintext, iv)
}

// OpenCall opens what SealCall sealed, as the same direction of the same
// call; anything else is ErrUnsealable.
func OpenCall(sealKey macenvelope.Key, d Direction, call macenvelope.Message, sealed string) ([]byte, error) {
	l, ok := d.label()
	if !ok {
		return nil, ErrUnsealable
	}
	plain, err := macenvelope.Open(sealKey, l, Call.Fields, call, sealed)
	if err != nil {
		return nil, ErrUnsealable
	}
	return plain, nil
}

// HostCallHeader is the header for a host call of body, signed with the
// attempt's call key.
func HostCallHeader(callKey macenvelope.Key, call macenvelope.Message, body []byte) (string, error) {
	return Call.Header(callKey, call, body)
}

// RequestHeader is the header for a WorkerAPI request of body.
func RequestHeader(dispatchKey macenvelope.Key, d macenvelope.Message, body []byte) (string, error) {
	return Request.Header(dispatchKey, d, body)
}

// ReportHeader is the header for a worker service's report of body.
func ReportHeader(dispatchKey macenvelope.Key, d macenvelope.Message, body []byte) (string, error) {
	return Report.Header(dispatchKey, d, body)
}

// Verified is a header's authenticated fields and the body hash it names.
type Verified struct {
	Fields   macenvelope.Message
	BodyHash string
}

func within(ts any, now int64) bool {
	t := int64(ts.(uint64))
	d := t - now
	return d >= -WindowMs && d <= WindowMs
}

func verify(e macenvelope.Envelope, key func(macenvelope.Message) (macenvelope.Key, error), header string, now int64) (Verified, error) {
	p, err := e.Parse(header)
	if err != nil {
		return Verified{}, err
	}
	if !within(p.Message["ts"], now) {
		return Verified{}, ErrOutsideWindow
	}
	k, err := key(p.Message)
	if err != nil || !e.VerifyHeader(k, p.Message, p.BodyHash, p.MAC) {
		return Verified{}, ErrBadMAC
	}
	return Verified{Fields: p.Message, BodyHash: p.BodyHash}, nil
}

func held(k macenvelope.Key) func(macenvelope.Message) (macenvelope.Key, error) {
	return func(macenvelope.Message) (macenvelope.Key, error) { return k, nil }
}

// VerifyHostCallHeaderUnder verifies a host call's header under callKey,
// the attempt's call key as its holder has it, at now (Unix ms). The
// generation and the member are CYFR's to check, against its standing.
func VerifyHostCallHeaderUnder(callKey macenvelope.Key, header string, now int64) (Verified, error) {
	return verify(Call, held(callKey), header, now)
}

// VerifyRequestHeader verifies a WorkerAPI request's header under the
// dispatch key the verifying worker service holds.
func VerifyRequestHeader(dispatchKey macenvelope.Key, header string, now int64) (Verified, error) {
	return verify(Request, held(dispatchKey), header, now)
}

// VerifyReportHeader verifies a worker service report's header under the
// dispatch key of the service it names, derived from root.
func VerifyReportHeader(root macenvelope.Key, header string, now int64) (Verified, error) {
	return verify(Report, func(m macenvelope.Message) (macenvelope.Key, error) {
		w, err := WorkerKey(root, m["service"].(string))
		return DispatchKey(w), err
	}, header, now)
}

// VerifyBody checks body against the hash a verified header named; another
// body is ErrBadMAC, as the one-step verifiers answer it.
func VerifyBody(bodyHash string, body []byte) error {
	if !macenvelope.VerifyBody(bodyHash, body) {
		return ErrBadMAC
	}
	return nil
}
