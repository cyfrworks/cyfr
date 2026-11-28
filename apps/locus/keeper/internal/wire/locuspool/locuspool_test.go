// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package locuspool

import (
	"encoding/hex"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"github.com/cyfr/locus/keeper/internal/wire/macenvelope"
	"github.com/cyfr/locus/keeper/internal/wire/wirejson"
	"github.com/cyfr/locus/keeper/internal/wire/wiretest"
)

type headerCase struct {
	Why      string  `json:"why"`
	Header   string  `json:"header"`
	Now      int64   `json:"now"`
	BodyHash *string `json:"body_hash"`
	Error    *string `json:"error"`
}

// listenerCase is a request of the runtime's pool route over HTTP, which
// today's Elixir listener runs (Locus.PoolRouteTest) and the Go listener
// runs from N3: here, its refusal's status and error.
type listenerCase struct {
	Why        string  `json:"why"`
	HTTP       bool    `json:"http"`
	Header     string  `json:"header"`
	HeaderText string  `json:"header_text" wire:"optional"`
	Body       string  `json:"body"`
	Keeper     string  `json:"keeper"`
	Status     int     `json:"status"`
	Error      *string `json:"error" wire:"null,required"`
	Answer     *string `json:"answer" wire:"null,required"`
	Refusal    *string `json:"refusal" wire:"null,required"`
	Closed     bool    `json:"closed"`
}

type service struct {
	Header        string `json:"header"`
	Label         string `json:"label"`
	PoolKeyHex    string `json:"pool_key_hex"`
	RequestKeyHex string `json:"request_key_hex" wire:"optional"`
}

// wireSection is locus_pool.json's wire, the pool wire's vectors.
type wireSection struct {
	Version         int                `json:"version"`
	Route           string             `json:"route"`
	AuthHeader      string             `json:"auth_header"`
	WindowMs        int                `json:"window_ms"`
	MaxRequestBytes int                `json:"max_request_bytes"`
	KeyHex          string             `json:"key_hex"`
	TS              int64              `json:"ts"`
	Body            string             `json:"body"`
	Services        map[string]service `json:"services"`
	Answer          string             `json:"answer"`
	Headers         struct {
		Accepted []headerCase `json:"accepted"`
		Refused  []headerCase `json:"refused"`
	} `json:"headers"`
	Verify     []headerCase `json:"verify"`
	BodyChecks []struct {
		Why      string `json:"why"`
		BodyHash string `json:"body_hash"`
		Body     string `json:"body"`
		Ok       bool   `json:"ok"`
	} `json:"body_checks"`
	RequestBodies []struct {
		Why   string  `json:"why"`
		Body  string  `json:"body"`
		After *uint64 `json:"after"`
		Error *string `json:"error"`
	} `json:"request_bodies"`
	Reports []struct {
		Why    string          `json:"why"`
		Report json.RawMessage `json:"report"`
		Answer *string         `json:"answer" wire:"null,required"`
	} `json:"reports"`
	Listener []listenerCase `json:"listener"`
}

func load(t *testing.T) wireSection {
	t.Helper()
	var v struct {
		Wire wireSection `json:"wire"`
	}
	wiretest.LoadStrict(t, "locus_pool.json", &v)
	return v.Wire
}

func key(t *testing.T, text string) macenvelope.Key {
	t.Helper()
	b, err := hex.DecodeString(text)
	if err != nil {
		t.Fatal(err)
	}
	k, ok := macenvelope.KeyFromBytes(b)
	if !ok {
		t.Fatalf("no key: %s", text)
	}
	return k
}

// poolKey is a service's pool key from the key the vectors give it: the
// builds service's through its request key, which is all it holds.
func poolKey(t *testing.T, w wireSection, name string) macenvelope.Key {
	t.Helper()
	held := key(t, w.KeyHex)
	if text := w.Services[name].RequestKeyHex; text != "" {
		held = key(t, text)
	}
	k, err := HeldPoolKey(name, held)
	if err != nil {
		t.Fatal(err)
	}
	return k
}

func TestThePoolWiresFiguresAreTheVectors(t *testing.T) {
	w := load(t)
	if w.Version != Version || w.Route != Route || w.AuthHeader != macenvelope.AuthHeader ||
		w.WindowMs != WindowMs || w.MaxRequestBytes != MaxRequestBytes {
		t.Errorf("the wire's figures %d %q %q %d %d", w.Version, w.Route, w.AuthHeader, w.WindowMs, w.MaxRequestBytes)
	}
}

// Each service's pool key derives from the key it holds over its own
// label, and its header verifies under that key alone: a header of one
// service is refused by the two others, all three given the same key.
func TestEachServicesPoolKeyAndHeaderAreItsOwn(t *testing.T) {
	w := load(t)
	if len(w.Services) != len(Services()) {
		t.Fatalf("%d services", len(w.Services))
	}
	for _, name := range Services() {
		v, ok := w.Services[name]
		if !ok {
			t.Fatalf("no %s", name)
		}
		if !poolKey(t, w, name).Equal(key(t, v.PoolKeyHex)) || envelope(name).Prefix != v.Label {
			t.Errorf("%s: its pool key or label", name)
		}
		for _, other := range Services() {
			_, err := VerifyHeader(other, poolKey(t, w, other), v.Header, w.TS)
			switch {
			case other == name && err != nil:
				t.Errorf("%s's header at %s: %v", name, other, err)
			case other != name && !errors.Is(err, ErrBadMAC):
				t.Errorf("%s's header at %s: %v, want bad_mac", name, other, err)
			}
		}
	}
	if _, err := HeldPoolKey("other", key(t, w.KeyHex)); !errors.Is(err, ErrUnknownService) {
		t.Errorf("another service: %v", err)
	}
	if _, err := VerifyHeader("runtime", macenvelope.Key{}, w.Services["runtime"].Header, w.TS); !errors.Is(err, ErrBadMAC) {
		t.Errorf("the zero Key verifies: %v", err)
	}
}

// Every header reads by the pool kind's grammar, or is refused, in the
// order Prima.LocusPool.verify_header/4 refuses: unknown_version,
// malformed, outside_window (the window inclusive), bad_mac.
func TestEveryHeaderVerifiesOrIsRefusedAsPrimaAnswers(t *testing.T) {
	w := load(t)
	pool := poolKey(t, w, "runtime")
	cases := append(append(append([]headerCase{}, w.Headers.Accepted...), w.Headers.Refused...), w.Verify...)
	if len(w.Headers.Accepted) < 4 || len(w.Headers.Refused) < 30 || len(w.Verify) < 10 {
		t.Fatalf("%d accepted, %d refused, %d verified", len(w.Headers.Accepted), len(w.Headers.Refused), len(w.Verify))
	}
	for _, c := range cases {
		if (c.BodyHash == nil) == (c.Error == nil) {
			t.Fatalf("%s: a case names its body hash or its error, one of them", c.Why)
		}
		hash, err := VerifyHeader("runtime", pool, c.Header, c.Now)
		switch {
		case c.Error != nil && (err == nil || err.Error() != *c.Error):
			t.Errorf("%s: %q, %v; want %s", c.Why, hash, err, *c.Error)
		case c.BodyHash != nil && (err != nil || hash != *c.BodyHash):
			t.Errorf("%s: %q, %v; want %s", c.Why, hash, err, *c.BodyHash)
		}
	}
}

func TestEveryBodyIsHeldToItsHash(t *testing.T) {
	w := load(t)
	if len(w.BodyChecks) < 3 {
		t.Fatalf("%d checks", len(w.BodyChecks))
	}
	for _, c := range w.BodyChecks {
		if err := VerifyBody(c.BodyHash, []byte(c.Body)); (err == nil) != c.Ok {
			t.Errorf("%s: %v", c.Why, err)
		}
	}
}

// Every request body reads to its rev, or is refused: another version, or
// none, before anything else of it is read.
func TestEveryRequestBodyReadsAsPrimaReadsIt(t *testing.T) {
	w := load(t)
	if len(w.RequestBodies) < 25 {
		t.Fatalf("%d bodies", len(w.RequestBodies))
	}
	for _, c := range w.RequestBodies {
		if (c.After == nil) == (c.Error == nil) {
			t.Fatalf("%s: a case names its rev or its error, one of them", c.Why)
		}
		rev, err := ReadRequestBody([]byte(c.Body))
		switch {
		case c.Error != nil && (err == nil || err.Error() != *c.Error):
			t.Errorf("%s: %d, %v; want %s", c.Why, rev, err, *c.Error)
		case c.After != nil && (err != nil || rev != *c.After):
			t.Errorf("%s: %d, %v; want %d", c.Why, rev, err, *c.After)
		}
	}
	if _, err := ReadRequestBody(make([]byte, 0)); !errors.Is(err, ErrMalformed) {
		t.Error("no body")
	}
}

// Every report reads strictly or is refused, and a read one is answered
// as Prima writes the answer, byte for byte: next only where more follow,
// a counter's athanor and subject only where it has them, at most 256
// counters.
func TestEveryReportReadsAndIsAnsweredAsPrimaDoes(t *testing.T) {
	w := load(t)
	if len(w.Reports) < 30 {
		t.Fatalf("%d reports", len(w.Reports))
	}
	read := 0
	for _, c := range w.Reports {
		decoded, err := wirejson.Read(c.Report)
		if err != nil {
			t.Fatal(err)
		}
		r, err := ReadReport(decoded)
		if c.Answer == nil {
			if err == nil {
				t.Errorf("%s: read; Prima refuses it", c.Why)
			}
			continue
		}
		read++
		answer, werr := Answer(r)
		if err != nil || werr != nil || string(answer) != *c.Answer {
			t.Errorf("%s: %v, %v; answered %.200s\nwant %.200s", c.Why, err, werr, answer, *c.Answer)
		}
	}
	if read < 6 {
		t.Errorf("%d reports read", read)
	}
	if _, err := Answer(Report{Boot: strings.Repeat("0", 32), Counters: make([]Counter, ReportCounters+1)}); !errors.Is(err, ErrMalformed) {
		t.Errorf("a report of 257 counters answered: %v", err)
	}
}

// Every listener case's refusal is answered with its status and error, as
// the worker service answers it (Locus.Runtime.WorkerListener); the cases
// themselves are run over HTTP by today's listener and by N3's.
func TestEveryPoolRefusalIsAnsweredWithItsStatus(t *testing.T) {
	w := load(t)
	if len(w.Listener) < 15 {
		t.Fatalf("%d listener cases", len(w.Listener))
	}
	stages := map[string]Stage{"unauthorized": Unauthorized, "too_large": TooLarge, "bad_body": BadBody, "unavailable": Unavailable}
	reasons := map[string]error{
		"unknown_version": macenvelope.ErrUnknownVersion, "malformed": macenvelope.ErrMalformed,
		"outside_window": ErrOutsideWindow, "bad_mac": ErrBadMAC, "version": ErrVersion,
	}
	for _, c := range w.Listener {
		if !c.HTTP {
			t.Fatalf("%s: a listener case is marked http", c.Why)
		}
		if c.Refusal == nil {
			if c.Status != 200 || c.Error != nil || c.Answer == nil {
				t.Errorf("%s: an answered case is 200 with its answer", c.Why)
			}
			continue
		}
		stage, reason, _ := strings.Cut(*c.Refusal, " ")
		r := Refusal{Stage: stages[stage], Reason: reasons[reason]}
		if stage == "bad_body" && reason == "malformed" {
			r.Reason = ErrMalformed
		}
		status, code, ok := r.Status()
		if !ok || c.Error == nil || status != c.Status || code != *c.Error || c.Answer != nil {
			t.Errorf("%s: %q answers %d %q, %v; want %d %v", c.Why, *c.Refusal, status, code, ok, c.Status, c.Error)
		}
	}
	if _, _, ok := (Refusal{}).Status(); ok {
		t.Error("a Refusal no route made has a status")
	}
}
