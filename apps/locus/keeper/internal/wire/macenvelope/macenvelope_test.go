// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package macenvelope

import (
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type base64Case struct {
	Text  string  `json:"text"`
	Bytes *string `json:"bytes_hex"`
}

// Every base64 text reads as Elixir's Base reads it, by
// tests/fixtures/wire_json.json, which Prima's test holds Base to.
func TestEveryBase64TextReadsAsPrimasDecoderReadsIt(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "..", "..", "..", "tests", "fixtures", "wire_json.json"))
	if err != nil {
		t.Fatal(err)
	}
	var v struct {
		Base64URL []base64Case `json:"base64url"`
		Base64    []base64Case `json:"base64"`
	}
	if err := json.Unmarshal(data, &v); err != nil || len(v.Base64URL) < 10 || len(v.Base64) < 10 {
		t.Fatalf("the vector file: %v", err)
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
	if !key.Equal(copied) || key.Equal(zero) || !zero.Equal(Key{}) {
		t.Error("keys compare by their bytes")
	}
}

// What is refused names the field and never the value it refused.
func TestARefusalNamesNoValue(t *testing.T) {
	e := Envelope{Prefix: "p", Kind: "k", Fields: []Field{{Name: "who", Type: String}, {Name: "n", Type: Integer}}}
	secret := "sk_secret value"
	_, err := e.Header(Key{}, Message{"who": secret, "n": uint64(1)}, nil)
	var invalid InvalidField
	if !errors.As(err, &invalid) || invalid.Name != "who" || strings.Contains(err.Error(), "secret") {
		t.Fatalf("an invalid field: %v", err)
	}
	if _, err := e.Parse("v1 kind=k who=" + secret); err == nil || strings.Contains(err.Error(), "secret") {
		t.Fatalf("a malformed header: %v", err)
	}
	if _, err := Open(Key{}, "l", nil, Message{}, "sk_secret"); err != ErrUnsealable {
		t.Fatalf("an unsealable value: %v", err)
	}
}

// A value sealed opens under the same key, label and fields only.
func TestASealedValueOpensAsItWasSealed(t *testing.T) {
	key, _ := DecodeRoot(strings.Repeat("ab", 32))
	fields := []Field{{Name: "id", Type: String}}
	iv := []byte("123456789012")
	sealed, err := Seal(key, "label", fields, Message{"id": "a"}, []byte("plain"), iv)
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
