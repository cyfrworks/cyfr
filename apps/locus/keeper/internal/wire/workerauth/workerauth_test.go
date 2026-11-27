// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package workerauth

import (
	"bytes"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
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

func attemptFields() macenvelope.Envelope { return macenvelope.Envelope{Fields: AttemptFields} }

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
	worker, err := WorkerKey(root, v.Service)
	if err != nil {
		t.Fatal(err)
	}
	callKey, err := AttemptCallKey(root, message(t, attemptFields(), v.Attempt))
	if err != nil {
		t.Fatal(err)
	}
	sealKey, _ := AttemptSealKey(root, message(t, attemptFields(), v.Attempt))
	for name, k := range map[string]macenvelope.Key{
		"assign_hex": AssignKey(root), "worker_hex": worker, "dispatch_hex": DispatchKey(worker),
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
	}{"request": {v.Request, Request, RequestHeader}, "report": {v.Report, Report, ReportHeader}} {
		m := v.dispatch(c.d)
		if got, err := c.header(dk, m, []byte(c.d.Body)); err != nil || got != c.d.Header {
			t.Errorf("the %s's header: %q, %v", name, got, err)
		}
		if got, _ := c.e.Canonical(m, []byte(c.d.Body)); got != c.d.Canonical {
			t.Errorf("the %s's canonical string: %q", name, got)
		}
	}
	if MaxCallHeaderBytes != 2322 {
		t.Errorf("the longest call header is %d bytes", MaxCallHeaderBytes)
	}
}

func TestSealedKeysAndSealedCallsReproduceAndOpen(t *testing.T) {
	v := load(t)
	keys, err := OpenAttemptKeys(key(t, v.Keys["dispatch_seal_hex"]), v.SealedAttemptKeys.Sealed)
	if err != nil || !keys.Call.Equal(key(t, v.Keys["attempt_call_hex"])) || !keys.Seal.Equal(key(t, v.Keys["attempt_seal_hex"])) {
		t.Fatalf("the sealed attempt keys: %v", err)
	}
	if fmt.Sprint(keys.Attempt) != fmt.Sprint(message(t, attemptFields(), v.Attempt)) {
		t.Errorf("the attempt they name: %v", keys.Attempt)
	}
	call := v.call(t)
	sc := v.SealedCall
	for _, c := range []struct {
		d             Direction
		plain, iv, at string
	}{{Body, v.Call.Body, sc.BodyIV, sc.BodySealed}, {Answer, sc.Answer, sc.AnswerIV, sc.AnswerSealed}} {
		iv, _ := hex.DecodeString(c.iv)
		if got, err := SealCall(keys.Seal, c.d, call, []byte(c.plain), iv); err != nil || got != c.at {
			t.Errorf("%s sealed: %q, %v", c.d, got, err)
		}
		if got, err := OpenCall(keys.Seal, c.d, call, c.at); err != nil || string(got) != c.plain {
			t.Errorf("%s opened: %q, %v", c.d, got, err)
		}
		if SealedBytes(len(c.plain)) != len(c.at) {
			t.Errorf("%s: %d bytes sealed, %d counted", c.d, len(c.at), SealedBytes(len(c.plain)))
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
			return VerifyReportHeader(key(t, v.RootHex), h, now)
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
		case fmt.Sprint(got.Fields) != fmt.Sprint(message(t, e, c.Fields)) || len(got.Fields) != len(c.Fields) || got.BodyHash != c.BodyHash:
			t.Errorf("%s %s: %v %s, want %v %s", c.Kind, c.Why, got.Fields, got.BodyHash, message(t, e, c.Fields), c.BodyHash)
		}
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
	for _, c := range v.OpenAttemptKeys {
		got, err := OpenAttemptKeys(dseal, c.Sealed)
		switch {
		case c.Error != nil:
			if !errors.Is(err, ErrUnsealable) {
				t.Errorf("%s: %v, want unsealable", c.Why, err)
			}
		case err != nil:
			t.Errorf("%s: %v", c.Why, err)
		case fmt.Sprint(got.Attempt) != fmt.Sprint(message(t, attemptFields(), c.Attempt)) ||
			!got.Call.Equal(key(t, c.CallHex)) || !got.Seal.Equal(key(t, c.SealHex)):
			t.Errorf("%s: opened as another attempt or keys: %v", c.Why, got.Attempt)
		}
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
			if !errors.Is(err, ErrUnsealable) {
				t.Errorf("%s: %q, %v; want unsealable", c.Why, got, err)
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
