// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package shell

import (
	"crypto/ed25519"
	"encoding/json"
	"strings"
	"testing"

	"github.com/cyfr/codex/internal/account"
)

// A device's first connection as tests/fixtures/device.json pins it: each
// hello is composed to its message, the answer to the sign-in request is
// device_1's signature reproduced byte for byte, and the admission is read
// as a client and certificate for that key and account at that CYFR, and
// refused for any other key, account or CYFR.
func TestDeviceVectors_TheFirstConnection(t *testing.T) {
	var v struct {
		Keys     map[string]struct{ Seed, Public string } `json:"keys"`
		Messages []struct {
			Message map[string]any `json:"message"`
			Name    string         `json:"name"`
			Sender  string         `json:"sender"`
		} `json:"messages"`
	}
	fixture(t, "device.json", &v)
	key, pub := keyOf(t, v.Keys["device_1"].Seed)
	if b64(pub) != v.Keys["device_1"].Public {
		t.Fatal("device_1's public key")
	}
	by := map[string]map[string]any{}
	hellos := 0
	for _, m := range v.Messages {
		typ, _ := m.Message["type"].(string)
		by[typ] = m.Message
		if typ != "hello" {
			continue
		}
		hellos++
		h := Hello{Key: pub, Identifier: m.Message["identifier"].(string), HolderKind: m.Message["holder_kind"].(string),
			DisplayName: m.Message["display_name"].(string)}
		if a, ok := m.Message["admission"].(map[string]any); ok {
			h.Admission = a
		}
		got := h.message()
		got["protocol"] = DeviceProtocol
		if a, b := jcsOf(t, got), jcsOf(t, m.Message); a != b {
			t.Errorf("%s:\n got %s\nwant %s", m.Name, a, b)
		}
	}
	if hellos != 3 || by["sign_in_request"] == nil || by["sign_in_answer"] == nil || by["admitted"] == nil {
		t.Fatalf("the fixture holds %d hellos and no first connection", hellos)
	}

	r, err := account.ReadRequest(by["sign_in_request"]["request"])
	if err != nil || r.Purpose != "sign_in" {
		t.Fatalf("the sign-in request: %v", err)
	}
	answer, err := r.Answer(account.Kid(pub), key.Sign)
	if err != nil || jcsOf(t, map[string]any{"type": "sign_in_answer", "protocol": DeviceProtocol, "answer": answer}) != jcsOf(t, by["sign_in_answer"]) {
		t.Fatalf("the answer: %v", err)
	}

	raw, _ := json.Marshal(by["admitted"])
	var m message
	_ = json.Unmarshal(raw, &m)
	h := Hello{Key: pub, Identifier: by["hello"]["identifier"].(string)}
	got, err := admittedHere(m, h, r.Audience)
	cert := by["admitted"]["certificate"].(map[string]any)
	if err != nil || got.ClientID != by["admitted"]["client_id"] || got.Athanor != cert["athanor"] {
		t.Fatalf("the admission: %+v %v", got, err)
	}
	other, _, _ := ed25519.GenerateKey(nil)
	for name, try := range map[string]func() error{
		"another key": func() error {
			_, err := admittedHere(m, Hello{Key: other, Identifier: h.Identifier}, r.Audience)
			return err
		},
		"another account": func() error {
			_, err := admittedHere(m, Hello{Key: pub, Identifier: "per_" + strings.Repeat("0", 64)}, r.Audience)
			return err
		},
		"another CYFR": func() error { _, err := admittedHere(m, h, "https://bob.example"); return err },
	} {
		if try() == nil {
			t.Errorf("an admission for %s is kept", name)
		}
	}
}

// A refused hello as device.json pins it: the message vector is read as
// its class and the sentence a person reads, and every refusal of a
// refused message the CYFR sends (no error, an error that is no object, an
// error with no message, a field it does not carry) is not read as one.
func TestDeviceVectors_ARefusalIsReadAsItsSentence(t *testing.T) {
	var v struct {
		Messages []struct {
			Message map[string]any `json:"message"`
			Name    string         `json:"name"`
		} `json:"messages"`
		Refusals []struct {
			Message map[string]any `json:"message"`
			Name    string         `json:"name"`
			Sender  string         `json:"sender"`
		} `json:"refusals"`
	}
	fixture(t, "device.json", &v)
	read, refused := 0, 0
	for _, m := range v.Messages {
		if m.Message["type"] != "refused" {
			continue
		}
		raw, _ := json.Marshal(m.Message)
		got, ok := readRefused(raw)
		want := m.Message["error"].(map[string]any)
		if !ok || got.Class != want["class"] || got.Message != want["message"] || sentence(got, "command line") != want["message"] {
			t.Errorf("%s: read %+v, %v", m.Name, got, ok)
		}
		read++
	}
	for _, r := range v.Refusals {
		if r.Message["type"] != "refused" || r.Sender != "home" {
			continue
		}
		raw, _ := json.Marshal(r.Message)
		if got, ok := readRefused(raw); ok {
			t.Errorf("%s: read as %+v", r.Name, got)
		}
		refused++
	}
	if read != 1 || refused < 4 {
		t.Fatalf("the fixture held %d refused messages and %d refusals of one", read, refused)
	}
}

func jcsOf(t *testing.T, v any) string {
	t.Helper()
	raw, _ := json.Marshal(v)
	d, _ := account.Decode(raw)
	out, err := account.JCS(d)
	if err != nil {
		t.Fatal(err)
	}
	return string(out)
}
