// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package macenvelope

import (
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"testing"

	"github.com/cyfr/locus/keeper/internal/wire/wiretest"
)

type base64Case struct {
	Text  string  `json:"text"`
	Bytes *string `json:"bytes_hex" wire:"null,required"`
}

// Every base64 text reads as Elixir's Base reads it, by
// tests/fixtures/wire_json.json, which Prima's test holds Base to.
func TestEveryBase64TextReadsAsPrimasDecoderReadsIt(t *testing.T) {
	var v struct {
		Base64URL []base64Case `json:"base64url"`
		Base64    []base64Case `json:"base64"`
	}
	wiretest.LoadStrict(t, "wire_json.json", &v)
	if len(v.Base64URL) < 10 || len(v.Base64) < 10 {
		t.Fatalf("%d and %d base64 texts", len(v.Base64URL), len(v.Base64))
	}
	for section, c := range map[string]struct {
		cases  []base64Case
		decode func(string) ([]byte, bool)
	}{"base64url": {v.Base64URL, DecodeURL}, "base64": {v.Base64, DecodeStd}} {
		for _, k := range c.cases {
			got, ok := c.decode(k.Text)
			switch {
			case k.Bytes == nil && ok:
				t.Errorf("%s %q reads as %x; Base refuses it", section, k.Text, got)
			case k.Bytes != nil && (!ok || hex.EncodeToString(got) != *k.Bytes):
				t.Errorf("%s %q reads as %x, %v; Base reads %s", section, k.Text, got, ok, *k.Bytes)
			}
		}
	}
}

// A key prints the same under every verb, its zero value and a copy
// alike, in a struct that holds it openly or not, and is never marshalled.
func TestAKeyPrintsNoneOfItsBytes(t *testing.T) {
	key, ok := DecodeRoot("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
	if !ok {
		t.Fatal("the root")
	}
	copied := key
	var zero Key
	type open struct{ Key Key }
	type hidden struct{ key Key }
	forbidden := []string{"0001020304050607", "\x00\x01\x02\x03", "[0 1 2 3", "AAECAwQF"}
	for _, v := range []any{key, copied, zero, &key, open{key}, hidden{key}, &hidden{key}, []Key{key}, map[string]Key{"k": key}} {
		for _, verb := range []string{"%v", "%+v", "%#v", "%s", "%q", "%x", "%X", "%d", "%o", "%b", "%c", "%U", "%e", "%f", "%g", "%t", "%p", "%8.3v", "%-x", "% x", "%#x"} {
			got := fmt.Sprintf(verb, v)
			for _, f := range forbidden {
				if strings.Contains(got, f) {
					t.Errorf("%s of %T prints %q", verb, v, got)
				}
			}
		}
		if got := fmt.Sprint(v); strings.Contains(got, "0001020304050607") {
			t.Errorf("Sprint of %T: %q", v, got)
		}
	}
	if got := fmt.Sprint(key, zero, copied); got != "Key(..) Key(..) Key(..)" {
		t.Errorf("a key, the zero key and a copy print %q", got)
	}
	if _, err := json.Marshal(open{key}); err == nil {
		t.Error("a key was marshalled")
	}
	if _, err := key.MarshalText(); err == nil {
		t.Error("a key was written as text")
	}
	if !key.Equal(copied) || key.Equal(zero) || zero.Equal(Key{}) {
		t.Error("keys compare by their bytes, and the zero Key equals none")
	}
}

// What is refused names the field and never the value it refused.
func TestARefusalNamesNoValue(t *testing.T) {
	e := Envelope{Prefix: "p", Kind: "k", Fields: []Field{{Name: "who", Type: String}, {Name: "n", Type: Integer}}}
	secret := "sk_secret value"
	key, _ := DecodeRoot(strings.Repeat("ab", 32))
	_, err := e.Header(key, Message{"who": secret, "n": uint64(1)}, nil)
	var invalid InvalidField
	if !errors.As(err, &invalid) || invalid.Name != "who" || strings.Contains(err.Error(), "secret") {
		t.Fatalf("an invalid field: %v", err)
	}
	if _, err := e.Parse("v1 kind=k who=" + secret); err == nil || strings.Contains(err.Error(), "secret") {
		t.Fatalf("a malformed header: %v", err)
	}
	if _, err := Open(key, "l", nil, Message{}, "sk_secret"); err != ErrUnsealable {
		t.Fatalf("an unsealable value: %v", err)
	}
}

// A value sealed opens under the same key, label and fields only.
func TestASealedValueOpensAsItWasSealed(t *testing.T) {
	key, _ := DecodeRoot(strings.Repeat("ab", 32))
	fields := []Field{{Name: "id", Type: String}}
	sealed, err := Seal(key, "label", fields, Message{"id": "a"}, []byte("plain"))
	if err != nil {
		t.Fatal(err)
	}
	if got, err := Open(key, "label", fields, Message{"id": "a"}, sealed); err != nil || string(got) != "plain" {
		t.Fatalf("opened: %q, %v", got, err)
	}
	other, _ := DecodeRoot(strings.Repeat("cd", 32))
	for name, open := range map[string]func() ([]byte, error){
		"another key":   func() ([]byte, error) { return Open(other, "label", fields, Message{"id": "a"}, sealed) },
		"another label": func() ([]byte, error) { return Open(key, "label2", fields, Message{"id": "a"}, sealed) },
		"another field": func() ([]byte, error) { return Open(key, "label", fields, Message{"id": "b"}, sealed) },
	} {
		if got, err := open(); err != ErrUnsealable {
			t.Errorf("%s: %q, %v", name, got, err)
		}
	}
	if got, err := Open(key, "label", fields, Message{"id": "a b"}, sealed); !errors.As(err, new(InvalidField)) {
		t.Errorf("an invalid field: %q, %v", got, err)
	}
}

// The zero Key is no key: a failed decode answers it, and it signs,
// verifies, derives, seals and opens nothing at any entry point, even
// where 32 zero bytes, a real key, would.
func TestTheZeroKeyIsNoKey(t *testing.T) {
	zeroBytes, ok := KeyFromBytes(make([]byte, 32))
	if !ok {
		t.Fatal("32 zero bytes are a key")
	}
	var zero Key
	bad, okRoot := DecodeRoot("not a root")
	short, okShort := KeyFromBytes([]byte("short"))
	if okRoot || okShort || !bad.Zero() || !short.Zero() || !zero.Zero() || zeroBytes.Zero() {
		t.Fatal("a failed decode answers the zero Key, and only it")
	}
	if zero.Equal(zeroBytes) || zero.Equal(zero) || zeroBytes.Equal(zero) {
		t.Error("the zero Key equals a key")
	}
	e := Envelope{Prefix: "p", Kind: "k", Fields: []Field{{Name: "ts", Type: Integer}}}
	m := Message{"ts": uint64(1)}
	forged, err := e.Header(zeroBytes, m, []byte("{}"))
	if err != nil {
		t.Fatal(err)
	}
	p, err := e.Parse(forged)
	if err != nil {
		t.Fatal(err)
	}
	if !e.Verify(zeroBytes, p, []byte("{}")) {
		t.Fatal("a header signed with 32 zero bytes verifies under them")
	}
	for name, k := range map[string]Key{"the zero Key": zero, "a failed DecodeRoot": bad, "a failed KeyFromBytes": short} {
		if _, err := e.Header(k, m, nil); !errors.Is(err, ErrNoKey) {
			t.Errorf("%s signs: %v", name, err)
		}
		if e.VerifyHeader(k, p.Message, p.BodyHash, p.MAC) || e.Verify(k, p, []byte("{}")) {
			t.Errorf("%s verifies a header 32 zero bytes signed", name)
		}
		if !Derive(k, "label").Zero() {
			t.Errorf("%s derives a key", name)
		}
		if _, err := Seal(k, "label", e.Fields, m, []byte("x")); err == nil {
			t.Errorf("%s seals", name)
		}
		sealed, _ := Seal(zeroBytes, "label", e.Fields, m, []byte("secret"))
		if got, err := Open(k, "label", e.Fields, m, sealed); !errors.Is(err, ErrUnsealable) {
			t.Errorf("%s opens what 32 zero bytes sealed: %q, %v", name, got, err)
		}
	}
}

// Prima's seals reproduce byte for byte under the ivs the vectors name:
// worker_auth.json's sealed call halves and sealed attempt keys. Only this
// test gives seal an iv.
func TestPrimasSealsReproduce(t *testing.T) {
	var v struct {
		Attempt map[string]json.RawMessage `json:"attempt"`
		Boot    string                     `json:"boot"`
		Member  string                     `json:"member"`
		Keys    map[string]string          `json:"keys"`
		Call    struct {
			Body   string `json:"body"`
			Nonce  string `json:"nonce"`
			Runner string `json:"runner"`
			TS     uint64 `json:"ts"`
			// Held by workerauth's test, not compared here.
			Canonical json.RawMessage `json:"canonical"`
			Header    json.RawMessage `json:"header"`
		} `json:"call"`
		SealedAttemptKeys struct {
			IV     string `json:"iv_hex"`
			Sealed string `json:"sealed"`
		} `json:"sealed_attempt_keys"`
		SealedCall struct {
			Answer       string `json:"answer"`
			AnswerIV     string `json:"answer_iv_hex"`
			AnswerSealed string `json:"answer_sealed"`
			BodyIV       string `json:"body_iv_hex"`
			BodySealed   string `json:"body_sealed"`
		} `json:"sealed_call"`
	}
	wiretest.LoadStrict(t, "worker_auth.json", &v)
	if v.SealedCall.BodySealed == "" || v.SealedAttemptKeys.Sealed == "" {
		t.Fatal("the sealed call and attempt keys")
	}
	attemptFields := []Field{{"athanor_id", String, ""}, {"execution_id", String, ""}, {"attempt", String, ""},
		{"fence", Integer, ""}, {"generation", Integer, ""}, {"service", String, ""}}
	callFields := append(append([]Field{}, attemptFields...), Field{"boot", String, ""}, Field{"runner", String, ""},
		Field{"member", String, ""}, Field{"ts", Integer, ""}, Field{"nonce", String, ""})
	attempt := Message{}
	for _, f := range attemptFields {
		if f.Type == Integer {
			var n uint64
			json.Unmarshal(v.Attempt[f.Name], &n)
			attempt[f.Name] = n
		} else {
			var s string
			json.Unmarshal(v.Attempt[f.Name], &s)
			attempt[f.Name] = s
		}
	}
	call := Message{"boot": v.Boot, "runner": v.Call.Runner, "member": v.Member, "ts": v.Call.TS, "nonce": v.Call.Nonce}
	for k, val := range attempt {
		call[k] = val
	}
	key := func(name string) Key { k, _ := DecodeRoot(v.Keys[name]); return k }
	iv := func(h string) []byte { b, _ := hex.DecodeString(h); return b }
	sc := v.SealedCall
	for _, c := range []struct{ label, plain, iv, want string }{
		{"cyfr-locus/v1/runtime/call-body", v.Call.Body, sc.BodyIV, sc.BodySealed},
		{"cyfr-locus/v1/runtime/call-answer", sc.Answer, sc.AnswerIV, sc.AnswerSealed},
	} {
		if got, err := seal(key("attempt_seal_hex"), c.label, callFields, call, []byte(c.plain), iv(c.iv)); err != nil || got != c.want {
			t.Errorf("%s: %q, %v", c.label, got, err)
		}
	}
	keys, _ := hex.DecodeString(v.Keys["attempt_call_hex"] + v.Keys["attempt_seal_hex"])
	named, box, _ := strings.Cut(v.SealedAttemptKeys.Sealed, ".")
	if got, err := seal(key("dispatch_seal_hex"), "cyfr-locus/v1/runtime/attempt-keys", attemptFields, attempt, keys, iv(v.SealedAttemptKeys.IV)); err != nil || got != box {
		t.Errorf("the attempt keys: %q, %v (named %s)", got, err, named)
	}
}
