// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package workerauth

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/cyfr/locus/keeper/internal/wire/macenvelope"
)

// vectors is the part of tests/fixtures/worker_auth.json, the vector file
// of Prima.WorkerAuth, that a worker service's side reproduces.
type vectors struct {
	RootHex  string `json:"root_hex"`
	RootText struct {
		Valid   []string `json:"valid"`
		Invalid []string `json:"invalid"`
	} `json:"root_text"`
	Service string                     `json:"service"`
	Boot    string                     `json:"boot"`
	Member  string                     `json:"member"`
	Attempt map[string]json.RawMessage `json:"attempt"`
	Keys    map[string]string          `json:"keys"`
	Call    struct {
		Body      string `json:"body"`
		Canonical string `json:"canonical"`
		Header    string `json:"header"`
		Nonce     string `json:"nonce"`
		Runner    string `json:"runner"`
		TS        uint64 `json:"ts"`
	} `json:"call"`
	Request           dispatchVector `json:"request"`
	Report            dispatchVector `json:"report"`
	SealedAttemptKeys struct {
		Sealed string `json:"sealed"`
	} `json:"sealed_attempt_keys"`
	SealedCall struct {
		Answer       string `json:"answer"`
		AnswerIV     string `json:"answer_iv_hex"`
		AnswerSealed string `json:"answer_sealed"`
		BodyIV       string `json:"body_iv_hex"`
		BodySealed   string `json:"body_sealed"`
	} `json:"sealed_call"`
	Headers struct {
		Accepted []headerCase `json:"accepted"`
		Refused  []headerCase `json:"refused"`
	} `json:"headers"`
	Verify     []headerCase `json:"verify"`
	BodyChecks []struct {
		Why      string  `json:"why"`
		BodyHash string  `json:"body_hash"`
		Body     string  `json:"body_b64"`
		Error    *string `json:"error"`
	} `json:"body_checks"`
	OpenAttemptKeys []struct {
		Why     string                     `json:"why"`
		Sealed  string                     `json:"sealed"`
		Attempt map[string]json.RawMessage `json:"attempt"`
		CallHex string                     `json:"call_hex"`
		SealHex string                     `json:"seal_hex"`
		Error   *string                    `json:"error"`
		// Go is the Go reader's own answer where the two ends differ.
		Go *struct {
			Error string `json:"error"`
		} `json:"go"`
	} `json:"open_attempt_keys"`
	OpenCall []struct {
		Why       string                     `json:"why"`
		Direction string                     `json:"direction"`
		Call      map[string]json.RawMessage `json:"call"`
		Sealed    string                     `json:"sealed"`
		Plaintext *string                    `json:"plaintext_b64"`
		Error     *string                    `json:"error"`
	} `json:"open_call"`
}

type dispatchVector struct {
	Body      string `json:"body"`
	Canonical string `json:"canonical"`
	Header    string `json:"header"`
	Nonce     string `json:"nonce"`
	TS        uint64 `json:"ts"`
}

type headerCase struct {
	Kind     string                     `json:"kind"`
	Why      string                     `json:"why"`
	Header   string                     `json:"header"`
	Now      int64                      `json:"now"`
	Fields   map[string]json.RawMessage `json:"fields"`
	BodyHash string                     `json:"body_hash"`
	Error    *string                    `json:"error"`
}

// What only CYFR does with the root, made here to reproduce the vectors:
// the service holds none of it.
func assignKey(root macenvelope.Key) macenvelope.Key {
	return macenvelope.Derive(root, label+"/assign")
}

// deriveOver is the key Prima.MacEnvelope derives from root over label and
// each of fields' values in m, one per line, an integer in decimal.
func deriveOver(root macenvelope.Key, label string, fields []macenvelope.Field, m macenvelope.Message) (macenvelope.Key, error) {
	text := []string{label}
	for _, f := range fields {
		switch v := m[f.Name].(type) {
		case string:
			text = append(text, v)
		case uint64:
			text = append(text, strconv.FormatUint(v, 10))
		default:
			return macenvelope.Key{}, macenvelope.InvalidField{Name: f.Name}
		}
	}
	return macenvelope.Derive(root, strings.Join(text, "\n")), nil
}

func workerKey(root macenvelope.Key, service string) (macenvelope.Key, error) {
	return deriveOver(root, label, dispatchFields[:1], macenvelope.Message{"service": service})
}

func attemptCallKey(root macenvelope.Key, attempt macenvelope.Message) (macenvelope.Key, error) {
	return deriveOver(root, label+"/call", AttemptFields(), attempt)
}

func attemptSealKey(root macenvelope.Key, attempt macenvelope.Message) (macenvelope.Key, error) {
	return deriveOver(root, label+"/seal", AttemptFields(), attempt)
}

func requestHeader(dispatchKey macenvelope.Key, d macenvelope.Message, body []byte) (string, error) {
	return Request.Header(dispatchKey, d, body)
}

func verifyReportHeader(root macenvelope.Key, header string, now int64) (Verified, error) {
	p, err := Report.Parse(header)
	if err != nil {
		return Verified{}, err
	}
	w, err := workerKey(root, p.Message["service"].(string))
	if err != nil {
		return Verified{}, err
	}
	return verify(Report, DispatchKey(w), header, now)
}

// sameFields is whether a verified header's fields are the case's, each of
// its type: an integer field a JSON number of the same value, a string
// field a JSON string of the same text, and no field more or less.
func sameFields(e macenvelope.Envelope, got macenvelope.Message, raw map[string]json.RawMessage) bool {
	if len(got) != len(e.Fields) || len(raw) != len(e.Fields) {
		return false
	}
	for _, f := range e.Fields {
		r := raw[f.Name]
		switch f.Type {
		case macenvelope.Integer:
			n, isInt := got[f.Name].(uint64)
			if !isInt || string(r) != strconv.FormatUint(n, 10) {
				return false
			}
		default:
			s, isText := got[f.Name].(string)
			var want string
			if !isText || len(r) == 0 || r[0] != '"' || json.Unmarshal(r, &want) != nil || want != s {
				return false
			}
		}
	}
	return true
}

func load(t *testing.T) vectors {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "..", "..", "..", "tests", "fixtures", "worker_auth.json"))
	if err != nil {
		t.Fatal(err)
	}
	var v vectors
	if err := json.Unmarshal(data, &v); err != nil {
		t.Fatal(err)
	}
	return v
}

func key(t *testing.T, text string) macenvelope.Key {
	t.Helper()
	k, ok := macenvelope.DecodeRoot(text)
	if !ok {
		t.Fatalf("no key in %q", text)
	}
	return k
}

// message reads a vector's fields as the envelope's types: an integer
// field's JSON number as a uint64, a string field's string.
func message(t *testing.T, e macenvelope.Envelope, raw map[string]json.RawMessage) macenvelope.Message {
	t.Helper()
	m := macenvelope.Message{}
	for _, f := range e.Fields {
		r, ok := raw[f.Name]
		if !ok {
			continue
		}
		if f.Type == macenvelope.Integer {
			var n uint64
			if err := json.Unmarshal(r, &n); err != nil {
				t.Fatalf("%s: %v", f.Name, err)
			}
			m[f.Name] = n
		} else {
			var s string
			if err := json.Unmarshal(r, &s); err != nil {
				t.Fatalf("%s: %v", f.Name, err)
			}
			m[f.Name] = s
		}
	}
	return m
}

func attemptFields() macenvelope.Envelope { return macenvelope.Envelope{Fields: AttemptFields()} }

func (v vectors) call(t *testing.T) macenvelope.Message {
	m := message(t, attemptFields(), v.Attempt)
	m["boot"], m["runner"], m["member"], m["ts"], m["nonce"] = v.Boot, v.Call.Runner, v.Member, v.Call.TS, v.Call.Nonce
	return m
}

func (v vectors) dispatch(d dispatchVector) macenvelope.Message {
	return macenvelope.Message{"service": v.Service, "boot": v.Boot, "ts": d.TS, "nonce": d.Nonce}
}

func hexOf(k macenvelope.Key, t *testing.T, want string) bool {
	t.Helper()
	return k.Equal(key(t, want))
}

func TestEveryKeyDerivesAsTheVectorsSay(t *testing.T) {
	v := load(t)
	root := key(t, v.RootHex)
	worker, err := workerKey(root, v.Service)
	if err != nil {
		t.Fatal(err)
	}
	callKey, err := attemptCallKey(root, message(t, attemptFields(), v.Attempt))
	if err != nil {
		t.Fatal(err)
	}
	sealKey, _ := attemptSealKey(root, message(t, attemptFields(), v.Attempt))
	for name, k := range map[string]macenvelope.Key{
		"assign_hex": assignKey(root), "worker_hex": worker, "dispatch_hex": DispatchKey(worker),
		"dispatch_seal_hex": DispatchSealKey(worker), "attempt_call_hex": callKey, "attempt_seal_hex": sealKey,
	} {
		if !hexOf(k, t, v.Keys[name]) {
			t.Errorf("%s differs from the vector's", name)
		}
	}
	for _, text := range v.RootText.Valid {
		if k, ok := macenvelope.DecodeRoot(text); !ok || !k.Equal(root) {
			t.Errorf("valid root text %q", text)
		}
	}
	for _, text := range v.RootText.Invalid {
		if _, ok := macenvelope.DecodeRoot(text); ok {
			t.Errorf("invalid root text %q reads", text)
		}
	}
}

func TestEveryHeaderAndCanonicalStringReproduces(t *testing.T) {
	v := load(t)
	call := v.call(t)
	callKey := key(t, v.Keys["attempt_call_hex"])
	if got, err := HostCallHeader(callKey, call, []byte(v.Call.Body)); err != nil || got != v.Call.Header {
		t.Errorf("the call's header: %q, %v", got, err)
	}
	if got, _ := Call.Canonical(call, []byte(v.Call.Body)); got != v.Call.Canonical {
		t.Errorf("the call's canonical string: %q", got)
	}
	dk := key(t, v.Keys["dispatch_hex"])
	for name, c := range map[string]struct {
		d      dispatchVector
		e      macenvelope.Envelope
		header func(macenvelope.Key, macenvelope.Message, []byte) (string, error)
	}{"request": {v.Request, Request, requestHeader}, "report": {v.Report, Report, ReportHeader}} {
		m := v.dispatch(c.d)
		if got, err := c.header(dk, m, []byte(c.d.Body)); err != nil || got != c.d.Header {
			t.Errorf("the %s's header: %q, %v", name, got, err)
		}
		if got, _ := c.e.Canonical(m, []byte(c.d.Body)); got != c.d.Canonical {
			t.Errorf("the %s's canonical string: %q", name, got)
		}
	}
	relay, err := os.ReadFile(filepath.Join("..", "..", "..", "..", "..", "..", "tests", "fixtures", "runner_relay.json"))
	if err != nil {
		t.Fatal(err)
	}
	var r struct {
		MaxSignedHeaderBytes int `json:"max_signed_header_bytes"`
	}
	if err := json.Unmarshal(relay, &r); err != nil || r.MaxSignedHeaderBytes == 0 || MaxCallHeaderBytes != r.MaxSignedHeaderBytes {
		t.Errorf("the longest call header is %d bytes; runner_relay.json's %d (%v)", MaxCallHeaderBytes, r.MaxSignedHeaderBytes, err)
	}
}

func TestSealedKeysAndSealedCallsReproduceAndOpen(t *testing.T) {
	v := load(t)
	keys, err := OpenAttemptKeys(key(t, v.Keys["dispatch_seal_hex"]), v.SealedAttemptKeys.Sealed)
	if err != nil || !keys.Call.Equal(key(t, v.Keys["attempt_call_hex"])) || !keys.Seal.Equal(key(t, v.Keys["attempt_seal_hex"])) {
		t.Fatalf("the sealed attempt keys: %v", err)
	}
	if !sameFields(attemptFields(), keys.Attempt, v.Attempt) {
		t.Errorf("the attempt they name: %v", keys.Attempt)
	}
	call := v.call(t)
	sc := v.SealedCall
	for _, c := range []struct {
		d         Direction
		plain, at string
	}{{Body, v.Call.Body, sc.BodySealed}, {Answer, sc.Answer, sc.AnswerSealed}} {
		if got, err := OpenCall(keys.Seal, c.d, call, c.at); err != nil || string(got) != c.plain {
			t.Errorf("%s opened: %q, %v", c.d, got, err)
		}
		if SealedBytes(len(c.plain)) != len(c.at) {
			t.Errorf("%s: %d bytes sealed, %d counted", c.d, len(c.at), SealedBytes(len(c.plain)))
		}
		first, err := SealCall(keys.Seal, c.d, call, []byte(c.plain))
		second, _ := SealCall(keys.Seal, c.d, call, []byte(c.plain))
		if err != nil || first == second || len(first) != len(c.at) {
			t.Errorf("%s: two seals of one plaintext share an iv or a length: %q %q", c.d, first, second)
		}
		if got, err := OpenCall(keys.Seal, c.d, call, first); err != nil || string(got) != c.plain {
			t.Errorf("%s: its own seal opened as %q, %v", c.d, got, err)
		}
	}
}

func verifier(t *testing.T, v vectors, kind string) (macenvelope.Envelope, func(string, int64) (Verified, error)) {
	switch kind {
	case "call":
		return Call, func(h string, now int64) (Verified, error) {
			return VerifyHostCallHeaderUnder(key(t, v.Keys["attempt_call_hex"]), h, now)
		}
	case "request":
		return Request, func(h string, now int64) (Verified, error) {
			return VerifyRequestHeader(key(t, v.Keys["dispatch_hex"]), h, now)
		}
	case "report":
		return Report, func(h string, now int64) (Verified, error) {
			return verifyReportHeader(key(t, v.RootHex), h, now)
		}
	}
	t.Fatalf("no kind %q", kind)
	return macenvelope.Envelope{}, nil
}

// Every header reads, or is refused, as Prima's verifier answers it: its
// grammar for each kind, and the refusals in their order.
func TestEveryHeaderVerifiesOrIsRefusedAsPrimaAnswers(t *testing.T) {
	v := load(t)
	cases := append(append(append([]headerCase{}, v.Headers.Accepted...), v.Headers.Refused...), v.Verify...)
	if len(v.Headers.Accepted) < 15 || len(v.Headers.Refused) < 90 || len(v.Verify) < 30 {
		t.Fatalf("%d accepted, %d refused, %d verify", len(v.Headers.Accepted), len(v.Headers.Refused), len(v.Verify))
	}
	for _, c := range cases {
		e, verify := verifier(t, v, c.Kind)
		got, err := verify(c.Header, c.Now)
		switch {
		case c.Error != nil:
			if err == nil || err.Error() != *c.Error {
				t.Errorf("%s %s: %v, want %s", c.Kind, c.Why, err, *c.Error)
			}
		case err != nil:
			t.Errorf("%s %s: %v", c.Kind, c.Why, err)
		case !sameFields(e, got.Fields, c.Fields) || got.BodyHash != c.BodyHash:
			t.Errorf("%s %s: %v %s, want %s %s", c.Kind, c.Why, got.Fields, got.BodyHash, c.Fields, c.BodyHash)
		}
	}
	if len(v.BodyChecks) < 3 {
		t.Fatalf("%d body checks", len(v.BodyChecks))
	}
	for _, c := range v.BodyChecks {
		body, _ := base64.StdEncoding.DecodeString(c.Body)
		err := VerifyBody(c.BodyHash, body)
		if (c.Error == nil) != (err == nil) || (err != nil && err.Error() != *c.Error) {
			t.Errorf("body %s: %v", c.Why, err)
		}
	}
}

func TestEverySealedKeysOpenOrAreRefusedAsPrimaAnswers(t *testing.T) {
	v := load(t)
	dseal := key(t, v.Keys["dispatch_seal_hex"])
	if len(v.OpenAttemptKeys) < 25 {
		t.Fatalf("%d cases", len(v.OpenAttemptKeys))
	}
	differences := 0
	for _, c := range v.OpenAttemptKeys {
		got, err := OpenAttemptKeys(dseal, c.Sealed)
		switch {
		case c.Go != nil:
			differences++
			if err == nil || err.Error() != c.Go.Error {
				t.Errorf("%s: %v; Go refuses it %s", c.Why, err, c.Go.Error)
			}
		case c.Error != nil:
			if err == nil || err.Error() != *c.Error {
				t.Errorf("%s: %v, want %s", c.Why, err, *c.Error)
			}
		case err != nil:
			t.Errorf("%s: %v", c.Why, err)
		case !sameFields(attemptFields(), got.Attempt, c.Attempt) ||
			!got.Call.Equal(key(t, c.CallHex)) || !got.Seal.Equal(key(t, c.SealHex)):
			t.Errorf("%s: opened as another attempt or keys: %v", c.Why, got.Attempt)
		}
	}
	if differences == 0 {
		t.Error("no case states the depth the two ends differ at")
	}
}

func TestEverySealedCallOpensOrIsRefusedAsPrimaAnswers(t *testing.T) {
	v := load(t)
	seal := key(t, v.Keys["attempt_seal_hex"])
	if len(v.OpenCall) < 12 {
		t.Fatalf("%d cases", len(v.OpenCall))
	}
	for _, c := range v.OpenCall {
		got, err := OpenCall(seal, Direction(c.Direction), message(t, Call, c.Call), c.Sealed)
		switch {
		case c.Error != nil:
			if err == nil || err.Error() != *c.Error {
				t.Errorf("%s: %q, %v; want %s", c.Why, got, err, *c.Error)
			}
		case err != nil:
			t.Errorf("%s: %v", c.Why, err)
		default:
			want, _ := base64.StdEncoding.DecodeString(*c.Plaintext)
			if !bytes.Equal(got, want) {
				t.Errorf("%s: %q", c.Why, got)
			}
		}
	}
}

// A refusal names no key and no value of what it refused, and AttemptKeys
// print their keys redacted.
func TestNothingSecretIsPrinted(t *testing.T) {
	v := load(t)
	keys, _ := OpenAttemptKeys(key(t, v.Keys["dispatch_seal_hex"]), v.SealedAttemptKeys.Sealed)
	for _, verb := range []string{"%v", "%+v", "%#v", "%s", "%x"} {
		got := fmt.Sprintf(verb, keys)
		if strings.Contains(got, v.Keys["attempt_call_hex"][:16]) || strings.Count(got, "Key(..)") != 2 {
			t.Errorf("%s prints %q", verb, got)
		}
	}
	_, err := VerifyRequestHeader(key(t, v.Keys["dispatch_hex"]), v.Request.Header, 0)
	if err == nil || strings.Contains(err.Error(), v.Boot) {
		t.Errorf("a refusal: %v", err)
	}
}

// The zero Key, and the key a failed decode answers, verify, sign, open,
// seal and derive nothing at any entry point of the service's, even where
// 32 zero bytes, a real key, would.
func TestTheZeroKeyGrantsNothing(t *testing.T) {
	v := load(t)
	zeroBytes, _ := macenvelope.KeyFromBytes(make([]byte, 32))
	bad, _ := macenvelope.DecodeRoot("not a root")
	d := macenvelope.Message{"service": "wrk_x", "boot": "b", "ts": uint64(1000), "nonce": "n"}
	forged, err := requestHeader(zeroBytes, d, []byte("{}"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := VerifyRequestHeader(zeroBytes, forged, 1000); err != nil {
		t.Fatalf("32 zero bytes are a key: %v", err)
	}
	call := v.call(t)
	callForged, _ := HostCallHeader(zeroBytes, call, []byte("{}"))
	sealed, _ := SealCall(zeroBytes, Body, call, []byte("secret"))
	for name, k := range map[string]macenvelope.Key{"the zero Key": {}, "a failed DecodeRoot": bad} {
		if _, err := VerifyRequestHeader(k, forged, 1000); !errors.Is(err, ErrBadMAC) {
			t.Errorf("%s verifies a request: %v", name, err)
		}
		if _, err := VerifyHostCallHeaderUnder(k, callForged, int64(v.Call.TS)); !errors.Is(err, ErrBadMAC) {
			t.Errorf("%s verifies a call: %v", name, err)
		}
		if got, err := OpenCall(k, Body, call, sealed); !errors.Is(err, ErrUnsealable) {
			t.Errorf("%s opens a call: %q", name, got)
		}
		if _, err := OpenAttemptKeys(k, v.SealedAttemptKeys.Sealed); !errors.Is(err, ErrUnsealable) {
			t.Errorf("%s opens attempt keys: %v", name, err)
		}
		if _, err := SealCall(k, Body, call, []byte("x")); err == nil {
			t.Errorf("%s seals a call", name)
		}
		if _, err := HostCallHeader(k, call, nil); err == nil {
			t.Errorf("%s signs a call", name)
		}
		if _, err := ReportHeader(k, d, nil); err == nil {
			t.Errorf("%s signs a report", name)
		}
		if !DispatchKey(k).Zero() || !DispatchSealKey(k).Zero() {
			t.Errorf("%s derives a dispatch key", name)
		}
	}
}
