// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package account

import (
	"bytes"
	"crypto/ed25519"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// fixture decodes tests/fixtures/name with its numbers as json.Number.
func fixture(t *testing.T, name string, v any) {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "..", "tests", "fixtures", name))
	if err != nil {
		t.Fatal(err)
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	if err := dec.Decode(v); err != nil {
		t.Fatal(err)
	}
}

type vectorKey struct {
	Alg, Kid, Public, Seed, Private, CredentialID string
}

func (k *vectorKey) UnmarshalJSON(raw []byte) error {
	var m map[string]string
	if err := json.Unmarshal(raw, &m); err != nil {
		return err
	}
	*k = vectorKey{m["alg"], m["kid"], m["public"], m["seed"], m["private"], m["credential_id"]}
	return nil
}

func (k vectorKey) priv(t *testing.T) ed25519.PrivateKey {
	seed, ok := UnB64(k.Seed, 32, 32)
	if !ok {
		t.Fatalf("seed %q", k.Seed)
	}
	return ed25519.NewKeyFromSeed(seed)
}

type identityVectors struct {
	Keys    map[string]vectorKey `json:"keys"`
	Entries map[string]struct {
		Entry  map[string]any `json:"entry"`
		Hash   string         `json:"hash"`
		Signer *string        `json:"signer"`
	} `json:"entries"`
	Identifiers map[string]struct {
		Identifier string `json:"identifier"`
		UserID     string `json:"user_id"`
	} `json:"identifiers"`
	UserIDs struct {
		RefusedIdentifiers []string `json:"refused_identifiers"`
		RefusedUserIDs     []string `json:"refused_user_ids"`
	} `json:"user_ids"`
	Chains []struct {
		Name    string          `json:"name"`
		Entries []string        `json:"entries"`
		State   *map[string]any `json:"state"`
		Error   *struct {
			Index               int
			Reason, Field, Kind string
		} `json:"error"`
	} `json:"chains"`
	Kits struct {
		Valid []struct{ Public, Seed string } `json:"valid"`
	} `json:"kits"`
}

func readIdentity(t *testing.T) identityVectors {
	var v identityVectors
	fixture(t, "identity.json", &v)
	return v
}

// Every key derives from its seed to its public key and kid; every entry
// an Ed25519 key signed is re-signed to its sig, and every entry hashes
// to its hash.
func TestIdentity_KeysEntriesAndHashes(t *testing.T) {
	v := readIdentity(t)
	for name, k := range v.Keys {
		pub, ok := UnB64(k.Public, 32, 65)
		if !ok || Kid(pub) != k.Kid {
			t.Errorf("%s: kid", name)
		}
		if k.Alg == "ed25519" && B64(k.priv(t).Public().(ed25519.PublicKey)) != k.Public {
			t.Errorf("%s: public key", name)
		}
	}
	for name, e := range v.Entries {
		if h, err := Hash(e.Entry); err != nil || h != e.Hash {
			t.Errorf("%s: hash %s %v", name, h, err)
		}
		if e.Signer == nil || v.Keys[*e.Signer].Alg != "ed25519" {
			continue
		}
		if _, isText := e.Entry["sig"].(string); !isText {
			continue
		}
		signed, err := Sign(e.Entry, v.Keys[*e.Signer].priv(t))
		if err != nil || signed["sig"] != e.Entry["sig"] {
			t.Errorf("%s: sig", name)
		}
	}
	for name, id := range v.Identifiers {
		raw, ok := UserID(id.Identifier)
		back, ok2 := IdentifierForUserID(raw)
		if !ok || !ok2 || B64(raw) != id.UserID || back != id.Identifier {
			t.Errorf("%s: user id", name)
		}
	}
	for _, s := range v.UserIDs.RefusedIdentifiers {
		if _, ok := UserID(s); ok {
			t.Errorf("identifier %q read", s)
		}
	}
	for _, s := range v.UserIDs.RefusedUserIDs {
		raw, _ := UnB64(s, 0, 64)
		if _, ok := IdentifierForUserID(raw); ok && s != "" {
			t.Errorf("user id %q read", s)
		}
	}
	for _, k := range v.Kits.Valid {
		seed, _ := UnB64(k.Seed, 32, 32)
		if B64(RecoveryKey(seed).Public().(ed25519.PublicKey)) != k.Public {
			t.Errorf("kit %s", k.Public)
		}
	}
}

// Every chain walks to its state, or to the index and reason of the
// first entry refused.
func TestIdentity_ChainsWalkToTheirStateOrRefusal(t *testing.T) {
	v := readIdentity(t)
	for _, c := range v.Chains {
		entries := make([]any, len(c.Entries))
		for i, n := range c.Entries {
			entries[i] = v.Entries[n].Entry
		}
		s, err := Walk(entries)
		if c.State != nil {
			if err != nil {
				t.Errorf("%s: %v", c.Name, err)
				continue
			}
			want := *c.State
			got := map[string]any{"identifier": s.Identifier, "directory": s.Directory, "head": s.Head,
				"seq": json.Number(itoa64(s.Seq)), "keys": keyMaps(s.Keys), "recovery": b64s(s.Recovery)}
			a, _ := JCS(got)
			b, _ := JCS(want)
			if string(a) != string(b) {
				t.Errorf("%s:\n got %s\nwant %s", c.Name, a, b)
			}
			continue
		}
		r, ok := err.(*Refusal)
		if !ok || r.Reason != c.Error.Reason || r.Index != c.Error.Index || r.Field != c.Error.Field || r.Kind != c.Error.Kind {
			t.Errorf("%s: %+v, want %+v", c.Name, err, *c.Error)
		}
	}
}

// Every WebAuthn case reaches its result, or the refusal of the first
// check that fails.
func TestIdentity_WebAuthnCases(t *testing.T) {
	var v struct {
		Keys     map[string]vectorKey `json:"keys"`
		Webauthn []struct {
			Name, Key, Challenge, Origin, Result, Error string
			RPID                                        string `json:"rp_id"`
			Assertion                                   map[string]any
		} `json:"webauthn"`
	}
	fixture(t, "identity.json", &v)
	for _, c := range v.Webauthn {
		a, ok := readAssertion(c.Assertion)
		pub, _ := UnB64(v.Keys[c.Key].Public, 65, 65)
		challenge, _ := UnB64(c.Challenge, 1, 64)
		var err error = refused("malformed")
		if ok {
			err = VerifyAssertion(a, pub, challenge, c.Origin, c.RPID)
		}
		switch {
		case c.Result == "ok" && err != nil:
			t.Errorf("%s: %v", c.Name, err)
		case c.Result != "ok" && (err == nil || err.(*Refusal).Reason != c.Error):
			t.Errorf("%s: %v, want %s", c.Name, err, c.Error)
		}
	}
}

func keyMaps(keys []Key) []any {
	out := make([]any, len(keys))
	for i, k := range keys {
		out[i] = k.Map()
	}
	return out
}

func itoa64(n int64) string { b, _ := json.Marshal(n); return string(b) }

// JCS sorts keys by UTF-16 code units and escapes strings as ECMAScript
// does; a fraction, a null and an integer past 2^53-1 are outside its
// domain, the top-level field named.
func TestJCS_SortsByUTF16AndRefusesWhatIsOutsideItsDomain(t *testing.T) {
	got, err := JCS(map[string]any{"\U0001F600": 1, "￿": 2, "a": "<&> \x01\"\\", "n": json.Number("-0"), "z": []any{true, "x"}})
	want := `{"a":"<&>` + " " + `\u0001\"\\","n":0,"z":[true,"x"],"` + "\U0001F600" + `":1,"` + "￿" + `":2}`
	if err != nil || string(got) != want {
		t.Fatalf("%s (%v)\nwant %s", got, err, want)
	}
	for name, v := range map[string]map[string]any{
		"a fraction":    {"x": json.Number("1.5")},
		"a null":        {"x": []any{nil}},
		"past 2^53 - 1": {"x": json.Number("9007199254740992")},
		"an exponent":   {"x": json.Number("1e3")},
	} {
		if _, err := JCS(v); err == nil || err.(*JCSError).Field != "x" {
			t.Errorf("%s: %v", name, err)
		}
	}
}
