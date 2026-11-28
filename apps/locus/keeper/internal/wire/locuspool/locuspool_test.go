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
// runs from N3: here, its refusal's status and error, and what of its
// body is left unread.
type listenerCase struct {
	Why           string  `json:"why"`
	HTTP          bool    `json:"http"`
	Header        string  `json:"header"`
	HeaderText    string  `json:"header_text" wire:"optional"`
	Body          string  `json:"body"`
	ContentLength *int    `json:"content_length" wire:"null,required"`
	Keeper        string  `json:"keeper"`
	Status        int     `json:"status"`
	Error         *string `json:"error" wire:"null,required"`
	Answer        *string `json:"answer" wire:"null,required"`
	Refusal       *string `json:"refusal" wire:"null,required"`
	Unread        *int    `json:"unread" wire:"null,required"`
	Closed        bool    `json:"closed"`
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

type vectors struct {
	// Kinds are a place's kinds, each with its class, which the keeper's
	// admission reads.
	Kinds map[string]string `json:"kinds"`
	Wire  wireSection       `json:"wire"`
}

func loadAll(t *testing.T) vectors {
	t.Helper()
	var v vectors
	wiretest.Load(t, "locus_pool.json", &v)
	return v
}

func load(t *testing.T) wireSection {
	t.Helper()
	return loadAll(t).Wire
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

// poolKey is the runtime's pool key from the key the vectors give it.
func poolKey(t *testing.T, w wireSection) macenvelope.Key {
	t.Helper()
	return HeldPoolKey(key(t, w.KeyHex))
}

func TestThePoolWiresFiguresAreTheVectors(t *testing.T) {
	w := load(t)
	if w.Version != Version || w.Route != Route || w.AuthHeader != macenvelope.AuthHeader ||
		w.WindowMs != WindowMs || w.MaxRequestBytes != MaxRequestBytes {
		t.Errorf("the wire's figures %d %q %q %d %d", w.Version, w.Route, w.AuthHeader, w.WindowMs, w.MaxRequestBytes)
	}
}

// The runtime's pool key derives from the key it holds over its own label,
// and its header verifies under that key, naming the hash of the wire's
// body; the builds and backends services' headers, signed under their own
// pool keys from the same key, are bad_mac under the runtime's. The wire's
// answer is the one Answer writes for its report, byte for byte.
func TestTheRuntimesPoolKeyHeaderBodyAndAnswerAreTheVectors(t *testing.T) {
	w := load(t)
	if len(w.Services) != 3 {
		t.Fatalf("%d services", len(w.Services))
	}
	runtime, ok := w.Services["runtime"]
	if !ok {
		t.Fatal("no runtime")
	}
	pool := poolKey(t, w)
	if !pool.Equal(key(t, runtime.PoolKeyHex)) || envelope().Prefix != runtime.Label {
		t.Error("the runtime's pool key or label")
	}
	hash, err := VerifyHeader(pool, runtime.Header, w.TS)
	if err != nil {
		t.Fatalf("the runtime's header: %v", err)
	}
	if err := VerifyBody(hash, []byte(w.Body)); err != nil {
		t.Errorf("the wire's body is not the one the runtime's header hashed: %v", err)
	}
	for _, other := range []string{"builds", "backends"} {
		v, ok := w.Services[other]
		if !ok {
			t.Fatalf("no %s", other)
		}
		if _, err := VerifyHeader(pool, v.Header, w.TS); !errors.Is(err, ErrBadMAC) {
			t.Errorf("%s's header under the runtime's key: %v, want bad_mac", other, err)
		}
	}
	if _, err := VerifyHeader(macenvelope.Key{}, runtime.Header, w.TS); !errors.Is(err, ErrBadMAC) {
		t.Errorf("the zero Key verifies: %v", err)
	}
	answer, err := wirejson.Read([]byte(w.Answer))
	if err != nil {
		t.Fatal(err)
	}
	r, err := ReadReport(answer.(map[string]any)["report"])
	if err != nil {
		t.Fatalf("the wire's answer's report: %v", err)
	}
	if written, err := Answer(r); err != nil || string(written) != w.Answer {
		t.Errorf("the wire's answer written %s, %v\nwant %s", written, err, w.Answer)
	}
}

// The kinds a counter may have are the vector's, every kind its class's.
func TestEveryKindIsTheVectors(t *testing.T) {
	v := loadAll(t)
	if len(v.Kinds) != len(kinds) {
		t.Errorf("the vector's kinds %v, the package's %v", v.Kinds, kinds)
	}
	for kind := range v.Kinds {
		if !kinds[kind] {
			t.Errorf("%s is no kind of the package's", kind)
		}
	}
}

// Every header reads by the pool kind's grammar, or is refused, in the
// order Prima.LocusPool.verify_header/4 refuses: unknown_version,
// malformed, outside_window (the window inclusive), bad_mac.
func TestEveryHeaderVerifiesOrIsRefusedAsPrimaAnswers(t *testing.T) {
	w := load(t)
	pool := poolKey(t, w)
	cases := append(append(append([]headerCase{}, w.Headers.Accepted...), w.Headers.Refused...), w.Verify...)
	if len(w.Headers.Accepted) < 4 || len(w.Headers.Refused) < 30 || len(w.Verify) < 10 {
		t.Fatalf("%d accepted, %d refused, %d verified", len(w.Headers.Accepted), len(w.Headers.Refused), len(w.Verify))
	}
	for _, c := range cases {
		if (c.BodyHash == nil) == (c.Error == nil) {
			t.Fatalf("%s: a case names its body hash or its error, one of them", c.Why)
		}
		hash, err := VerifyHeader(pool, c.Header, c.Now)
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
}

// Answer writes no report Prima would refuse to read: each change below,
// to a report the vectors read, is ErrMalformed, as is the zero Report.
func TestNoAnswerCarriesAReportPrimaRefuses(t *testing.T) {
	w := load(t)
	answer, _ := wirejson.Read([]byte(w.Answer))
	base, err := ReadReport(answer.(map[string]any)["report"])
	if err != nil || len(base.Counters) == 0 || base.Counters[0].Athanor == "" || base.Counters[0].Subject == "" {
		t.Fatalf("the wire's report %+v, %v", base, err)
	}
	if _, err := Answer(base); err != nil {
		t.Fatalf("the wire's report: %v", err)
	}
	past := uint64(wirejson.MaxSafeInteger) + 1
	for why, change := range map[string]func(r *Report){
		"the zero Report":                 func(r *Report) { *r = Report{} },
		"an empty boot":                   func(r *Report) { r.Boot = "" },
		"a boot in capitals":              func(r *Report) { r.Boot = strings.ToUpper(r.Boot) },
		"a budget past 2^53 - 1":          func(r *Report) { r.Budget = past },
		"no wall":                         func(r *Report) { r.Wall = "" },
		"a wall no keeper gives":          func(r *Report) { r.Wall = "vm" },
		"a next past 2^53 - 1":            func(r *Report) { r.Next = past },
		"257 counters":                    func(r *Report) { r.Counters = ascending(r.Counters[0], ReportCounters+1) },
		"a rev of 0":                      func(r *Report) { r.Counters[0].Rev = 0 },
		"a counter's bytes past 2^53 - 1": func(r *Report) { r.Counters[0].Bytes = past },
		"a day that is no date":           func(r *Report) { r.Counters[0].Day = "2026-13-01" },
		"no day":                          func(r *Report) { r.Counters[0].Day = "" },
		"a kind no place has":             func(r *Report) { r.Counters[0].Kind = "vm" },
		"an athanor of another grammar":   func(r *Report) { r.Counters[0].Athanor = "athanor one" },
		"a subject of another grammar":    func(r *Report) { r.Counters[0].Subject = "a b" },
		"counters in descending rev":      func(r *Report) { r.Counters = reversed(ascending(r.Counters[0], 2)) },
		"a rev given twice":               func(r *Report) { r.Counters = []Counter{r.Counters[0], r.Counters[0]} },
	} {
		r := base
		r.Counters = append([]Counter{}, base.Counters...)
		change(&r)
		if written, err := Answer(r); !errors.Is(err, ErrMalformed) {
			t.Errorf("%s: answered %s, %v", why, written, err)
		}
	}
}

// ascending are n copies of c, their revs 1 to n.
func ascending(c Counter, n int) []Counter {
	out := make([]Counter, n)
	for i := range out {
		out[i] = c
		out[i].Rev = uint64(i + 1)
	}
	return out
}

func reversed(cs []Counter) []Counter {
	out := make([]Counter, len(cs))
	for i, c := range cs {
		out[len(cs)-1-i] = c
	}
	return out
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
			if c.Status != 200 || c.Error != nil || c.Answer == nil || c.Unread != nil {
				t.Errorf("%s: an answered case is 200 with its answer", c.Why)
			}
			continue
		}
		// What a refusal leaves of the body: all of it where it closes
		// before reading, but one byte where it read past the bound.
		switch body := len(c.Body); {
		case c.Unread == nil || *c.Unread < 0 || *c.Unread > body:
			t.Errorf("%s: unread %v of %d bytes", c.Why, c.Unread, body)
		case *c.Refusal == "too_large declared" && (c.ContentLength == nil || *c.ContentLength <= MaxRequestBytes || *c.Unread != body):
			t.Errorf("%s: a declared length past the bound refuses before the body is read", c.Why)
		case *c.Refusal == "too_large read" && (c.ContentLength != nil || *c.Unread != body-MaxRequestBytes):
			t.Errorf("%s: a body past the bound is read to the bound", c.Why)
		}
		stage, reason, _ := strings.Cut(*c.Refusal, " ")
		r := Refusal{Stage: stages[stage], Reason: reasons[reason]}
		switch {
		case stage == "bad_body" && reason == "malformed":
			r.Reason = ErrMalformed
		case stage == "too_large" && reason != "declared" && reason != "read":
			t.Errorf("%s: a body past the bound is refused declared or read, not %q", c.Why, reason)
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
