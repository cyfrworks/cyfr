// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package shell

import (
	"bytes"
	"crypto/ed25519"
	"encoding/json"
	"errors"
	"maps"
	"os"
	"path/filepath"
	"slices"
	"testing"
)

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

type seedKey struct{ priv ed25519.PrivateKey }

func (k seedKey) Sign(msg []byte) []byte { return ed25519.Sign(k.priv, msg) }

func keyOf(t *testing.T, seed string) (seedKey, []byte) {
	t.Helper()
	raw, err := unb64(seed)
	if err != nil || len(raw) != 32 {
		t.Fatalf("seed %q", seed)
	}
	priv := ed25519.NewKeyFromSeed(raw)
	return seedKey{priv}, priv.Public().(ed25519.PublicKey)
}

// deviceCertVectors is the part of tests/fixtures/device_cert.json a
// signing device reproduces: its keys, the held challenges and their
// proofs.
type deviceCertVectors struct {
	Keys       map[string]struct{ Seed, Public string } `json:"keys"`
	Challenges map[string]json.RawMessage               `json:"challenges"`
	Proofs     map[string]map[string]any                `json:"proofs"`
}

// The shell's signer reproduces the existing purposes' proofs byte for
// byte: the same canonical bytes and Ed25519 signatures the home verifies.
func TestProve_ReproducesTheExistingPurposesProofs(t *testing.T) {
	var v deviceCertVectors
	fixture(t, "device_cert.json", &v)
	key, pub := keyOf(t, v.Keys["device_1"].Seed)
	if b64(pub) != v.Keys["device_1"].Public {
		t.Fatal("device_1's public key")
	}
	for _, purpose := range []string{"connect", "renew", "pair"} {
		var held map[string]any
		_ = json.Unmarshal(v.Challenges[purpose], &held)
		b := Binding{Home: held["home"].(string), Athanor: held["athanor"].(string), ClientID: held["client_id"].(string), DeviceKey: pub}
		c, err := Challenge(v.Challenges[purpose], purpose, b, nil)
		if err != nil {
			t.Fatalf("%s: %v", purpose, err)
		}
		proof, err := Prove(c, key)
		if err != nil {
			t.Fatal(err)
		}
		if proof["sig"] != v.Proofs[purpose]["sig"] {
			t.Errorf("%s: sig %v, want %v", purpose, proof["sig"], v.Proofs[purpose]["sig"])
		}
	}
}

// A challenge for another purpose, home, athanor, client or key, with an
// extra or missing field or a short nonce, is refused before signing.
func TestChallenge_RefusesWhatThisDeviceDidNotAskFor(t *testing.T) {
	var v deviceCertVectors
	fixture(t, "device_cert.json", &v)
	_, pub := keyOf(t, v.Keys["device_1"].Seed)
	var held map[string]any
	_ = json.Unmarshal(v.Challenges["connect"], &held)
	b := Binding{Home: held["home"].(string), Athanor: held["athanor"].(string), ClientID: held["client_id"].(string), DeviceKey: pub}
	for name, change := range map[string]func(map[string]any){
		"other purpose": func(m map[string]any) { m["purpose"] = "renew" },
		"other home":    func(m map[string]any) { m["home"] = "https://hub.example" },
		"other athanor": func(m map[string]any) { m["athanor"] = "ath_01a09fee-0000-7000-8000-00000000beef" },
		"other client":  func(m map[string]any) { m["client_id"] = "pcl_01a09fee-7c1d-7e2f-8a3b-4c5d6e7f8092" },
		"other key":     func(m map[string]any) { m["device_key"] = v.Keys["device_2"].Public },
		"extra field":   func(m map[string]any) { m["session_id"] = "ses_001" },
		"missing nonce": func(m map[string]any) { delete(m, "nonce") },
		"short nonce":   func(m map[string]any) { m["nonce"] = "lVv5yRCGLF4IOnJSOareuw" },
		"padded nonce":  func(m map[string]any) { m["nonce"] = m["nonce"].(string) + "=" },
		"string expiry": func(m map[string]any) { m["expires_at"] = "1790000060000" },
		"other version": func(m map[string]any) { m["protocol"] = "cyfr-device-proof/v2" },
		"carries a sig": func(m map[string]any) { m["sig"] = "AAAA" },
	} {
		m := map[string]any{}
		_ = json.Unmarshal(v.Challenges["connect"], &m)
		change(m)
		raw, _ := json.Marshal(m)
		if _, err := Challenge(raw, "connect", b, nil); !errors.Is(err, ErrRefusedChallenge) {
			t.Errorf("%s: %v, want a refusal", name, err)
		}
	}
}

// The canonical encoding reproduces Prima.Confirmation's digest of the
// confirmation vector's record, which a confirm challenge carries.
func TestDigest_ReproducesTheConfirmationRecordsDigest(t *testing.T) {
	var v struct {
		Digest string         `json:"digest"`
		Record map[string]any `json:"record"`
	}
	fixture(t, "confirmation.json", &v)
	got, err := Digest(v.Record)
	if err != nil || got != v.Digest {
		t.Fatalf("digest %q (%v), want %q", got, err, v.Digest)
	}
}

func TestCanonical_SortsByUTF16AndEscapesAsECMAScript(t *testing.T) {
	got, err := Canonical(map[string]any{"\U0001F600": 1, "￿": 2, "a": "<&> \x01\"\\", "n": json.Number("-0"), "z": []any{true, nil}})
	want := `{"a":"<&>` + " " + `\u0001\"\\","n":0,"z":[true,null],"` + "\U0001F600" + `":1,"` + "￿" + `":2}`
	if err != nil || string(got) != want {
		t.Fatalf("%s (%v)\nwant %s", got, err, want)
	}
	if _, err := Canonical(map[string]any{"x": json.Number("1.5")}); err == nil {
		t.Fatal("a fractional number encodes")
	}
}

// unlockVectors is tests/fixtures/device_unlock.json as a signing device
// reads it.
type unlockVectors struct {
	Protocol     string `json:"protocol"`
	CommonFields struct {
		Binding   []string `json:"binding"`
		Freshness []string `json:"freshness"`
	} `json:"common_fields"`
	PurposeFields map[string]struct {
		Fresh  bool     `json:"fresh"`
		Fields []string `json:"fields"`
	} `json:"purpose_fields"`
	Keys   map[string]struct{ Seed, Public string } `json:"keys"`
	Proofs map[string]map[string]any                `json:"proofs"`
	Verify []struct {
		Name   string         `json:"name"`
		Held   map[string]any `json:"held"`
		Proof  map[string]any `json:"proof"`
		Result string         `json:"result"`
		Error  string         `json:"error"`
	} `json:"verify"`
}

func bindingOf(m map[string]any, pub []byte) Binding {
	s := func(k string) string { v, _ := m[k].(string); return v }
	return Binding{Home: s("home"), Athanor: s("athanor"), ClientID: s("client_id"), DeviceKey: pub}
}

// expectOf is what a device asked for, as a proof names it: the
// enrollment's admission and request, the session a lock ends, the
// confirmation's ref and digest.
func expectOf(m map[string]any) Expect {
	e := Expect{}
	for _, k := range []string{"admission", "request_id", "ref", "digest", "session_id"} {
		if v, ok := m[k].(string); ok {
			e[k] = v
		}
	}
	return e
}

func without(m map[string]any, key string) map[string]any {
	c := map[string]any{}
	for k, v := range m {
		if k != key {
			c[k] = v
		}
	}
	return c
}

// The field lists the shell checks are the fixture's, purpose by purpose.
func TestUnlockVectors_FieldListsAreTheFixtures(t *testing.T) {
	var v unlockVectors
	fixture(t, "device_unlock.json", &v)
	if v.Protocol != ProofProtocol || !slices.Equal(v.CommonFields.Binding, bindingFields) || !slices.Equal(v.CommonFields.Freshness, freshFields) {
		t.Fatalf("common fields %+v", v.CommonFields)
	}
	for purpose, p := range v.PurposeFields {
		want := slices.Clone(bindingFields)
		if p.Fresh {
			want = append(want, freshFields...)
		}
		got, ok := fieldsOf(purpose)
		if !ok || !slices.Equal(got, append(want, p.Fields...)) {
			t.Errorf("%s: %v, want %v", purpose, got, append(want, p.Fields...))
		}
	}
	for _, purpose := range []string{"enroll", "unlock", "confirm", "lock"} {
		if _, ok := v.PurposeFields[purpose]; !ok {
			t.Errorf("the fixture names no %s", purpose)
		}
	}
}

// The four worked examples are reproduced byte for byte: enroll, unlock
// and confirm from their held challenges, lock from what the device knows.
func TestUnlockVectors_ReproducesTheFourProofs(t *testing.T) {
	var v unlockVectors
	fixture(t, "device_unlock.json", &v)
	key, pub := keyOf(t, v.Keys["device_1"].Seed)
	for _, purpose := range []string{"enroll", "unlock", "confirm"} {
		want := v.Proofs[purpose]
		raw, _ := json.Marshal(without(want, "sig"))
		c, err := Challenge(raw, purpose, bindingOf(want, pub), expectOf(want))
		if err != nil {
			t.Fatalf("%s: %v", purpose, err)
		}
		proof, _ := Prove(c, key)
		if proof["sig"] != want["sig"] {
			t.Errorf("%s: sig %v, want %v", purpose, proof["sig"], want["sig"])
		}
	}
	lock := v.Proofs["lock"]
	proof, err := LockProof(bindingOf(lock, pub), lock["session_id"].(string), key)
	if err != nil || proof["sig"] != lock["sig"] {
		t.Fatalf("lock: %v (%v), want %v", proof["sig"], err, lock["sig"])
	}
	if _, ok := proof["nonce"]; ok {
		t.Fatal("a lock proof carries a nonce")
	}
}

// Every verify case the home refuses is a proof this device never makes
// from the held challenge while expecting the proof's own binding: the
// signer refuses the held challenge, or what it signs is not the refused
// proof. Expiry and replay are the home's clock and store, not the
// signer's, and the ok cases reproduce their proof exactly.
func TestUnlockVectors_TheSignerNeverMakesARefusedProof(t *testing.T) {
	var v unlockVectors
	fixture(t, "device_unlock.json", &v)
	signerNeverMakesARefusedProof(t, v)
}

// signerNeverMakesARefusedProof holds v's verify cases to the signer, as
// TestUnlockVectors_TheSignerNeverMakesARefusedProof says; device_pin.json
// has its own (pin_test.go).
func signerNeverMakesARefusedProof(t *testing.T, v unlockVectors) {
	t.Helper()
	key, pub := keyOf(t, v.Keys["device_1"].Seed)
	for _, c := range v.Verify {
		purpose, _ := c.Proof["purpose"].(string)
		heldRaw, _ := json.Marshal(c.Held)
		held, err := Challenge(heldRaw, purpose, bindingOf(c.Proof, pub), expectOf(c.Proof))
		if purpose == "lock" && err == nil {
			// A lock is built, not answered: the device signs its own.
			proof, _ := LockProof(bindingOf(c.Proof, pub), stringOf(c.Proof, "session_id"), key)
			held = without(proof, "sig")
		}
		switch {
		case c.Result == "ok":
			if err != nil {
				t.Errorf("%s: refused (%v)", c.Name, err)
				continue
			}
			proof, _ := Prove(held, key)
			if proof["sig"] != c.Proof["sig"] {
				t.Errorf("%s: sig %v, want %v", c.Name, proof["sig"], c.Proof["sig"])
			}
		case c.Error == "expired" || c.Error == "no_challenge":
		case err == nil:
			if f := differing(c.Held, without(c.Proof, "sig")); c.Error == "challenge_mismatch" && knows(purpose, f) {
				t.Errorf("%s: the signer signs a challenge whose %s is not what it asked for", c.Name, f)
			}
			proof, _ := Prove(held, key)
			mine, _ := Canonical(proof)
			theirs, _ := Canonical(c.Proof)
			if bytes.Equal(mine, theirs) {
				t.Errorf("%s: the signer makes the refused proof", c.Name)
			}
		}
	}
}

func stringOf(m map[string]any, k string) string { s, _ := m[k].(string); return s }

// differing is the first field two challenges disagree on, "" for none.
func differing(a, b map[string]any) string {
	keys := map[string]bool{}
	for k := range a {
		keys[k] = true
	}
	for k := range b {
		keys[k] = true
	}
	for _, k := range slices.Sorted(maps.Keys(keys)) {
		ra, _ := Canonical(a[k])
		rb, _ := Canonical(b[k])
		if _, inA := a[k]; !inA || !bytes.Equal(ra, rb) {
			return k
		}
		if _, inB := b[k]; !inB {
			return k
		}
	}
	return ""
}

// knows is whether a device itself knows field of a purpose's challenge:
// its binding and what it asked for, a lock's session included. The
// nonce, the expiry, an unlock's reserved session and a record's digest
// are the home's to choose.
func knows(purpose, field string) bool {
	switch field {
	case "protocol", "purpose", "home", "athanor", "client_id", "device_key", "admission", "request_id", "ref":
		return true
	case "session_id":
		return purpose == "lock"
	}
	return false
}
