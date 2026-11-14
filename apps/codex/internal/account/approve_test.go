// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package account_test

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/cyfr/codex/internal/account"
	"github.com/cyfr/codex/internal/account/accounttest"
)

// A device key adds a passkey to its account as identity.json's chain "a
// passkey added by the device" does: the entry kept is that chain's add_key
// byte for byte, the log walks to the chain's keys, and a second approval
// of the same passkey is ErrListed and keeps nothing more.
func TestApprove_AddsAPasskeyAsTheFixturesChainDoes(t *testing.T) {
	type chain struct {
		Name    string         `json:"name"`
		Entries []string       `json:"entries"`
		State   map[string]any `json:"state"`
	}
	var v struct {
		Keys    map[string]map[string]string `json:"keys"`
		Entries map[string]struct {
			Entry map[string]any `json:"entry"`
		} `json:"entries"`
		Chains []chain `json:"chains"`
	}
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "..", "tests", "fixtures", "identity.json"))
	if err != nil {
		t.Fatal(err)
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	if err := dec.Decode(&v); err != nil {
		t.Fatal(err)
	}
	var added chain
	for _, c := range v.Chains {
		if c.Name == "a passkey added by the device" {
			added = c
		}
	}
	if len(added.Entries) != 3 {
		t.Fatalf("identity.json holds no chain of a passkey added by the device: %+v", added)
	}
	identifier := added.State["identifier"].(string)
	svc := accounttest.New(t)
	for _, name := range added.Entries[:2] {
		svc.Append(t, identifier, v.Entries[name].Entry)
	}

	seed, _ := account.UnB64(v.Keys["device_1"]["seed"], 32, 32)
	device := ed25519.NewKeyFromSeed(seed)
	pk := v.Keys["passkey_1"]
	passkey, ok := account.ReadKey(map[string]any{"kid": pk["kid"], "alg": pk["alg"], "kind": "passkey",
		"pub": pk["public"], "credential_id": pk["credential_id"]})
	if !ok {
		t.Fatal("passkey_1's descriptor does not read")
	}
	want := v.Entries[added.Entries[2]].Entry
	at, err := want["at"].(json.Number).Int64()
	if err != nil {
		t.Fatal(err)
	}
	d := account.Directory{URL: svc.URL()}
	sign := func(m []byte) []byte { return ed25519.Sign(device, m) }
	if err := account.Approve(context.Background(), d, identifier, device.Public().(ed25519.PublicKey), sign, passkey, at); err != nil {
		t.Fatal(err)
	}

	log := svc.Log(identifier)
	got, _ := account.JCS(log[len(log)-1])
	wanted, _ := account.JCS(want)
	if len(log) != 3 || !bytes.Equal(got, wanted) {
		t.Fatalf("the log kept %d entries, the last\n %s\nwant %s", len(log), got, wanted)
	}
	st := svc.State(t, identifier)
	keys := make([]any, len(st.Keys))
	for i, k := range st.Keys {
		keys[i] = k.Map()
	}
	gotKeys, _ := account.JCS(keys)
	wantKeys, _ := account.JCS(added.State["keys"])
	if !bytes.Equal(gotKeys, wantKeys) || st.Head != added.State["head"] {
		t.Fatalf("the log walks to head %s, keys\n %s\nwant %s, keys\n %s", st.Head, gotKeys, added.State["head"], wantKeys)
	}

	writes := svc.Writes
	err = account.Approve(context.Background(), d, identifier, device.Public().(ed25519.PublicKey), sign, passkey, at+1)
	if !errors.Is(err, account.ErrListed) || len(svc.Log(identifier)) != 3 || svc.Writes != writes {
		t.Fatalf("a second approval is %v, the log holds %d entries, %d writes after %d", err, len(svc.Log(identifier)), svc.Writes, writes)
	}
}
