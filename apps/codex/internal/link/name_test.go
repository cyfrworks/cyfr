// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package link

import (
	"bytes"
	"crypto/ecdh"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// vectors is tests/fixtures/link.json, which Cyfr.RuntimeConfig reads
// too.
type vectors struct {
	Names []struct {
		Why     string `json:"why"`
		Key     string `json:"key"`
		Public  string `json:"public"`
		Name    string `json:"name"`
		Port    int    `json:"port"`
		Address string `json:"address"`
	} `json:"names"`
	Refused []struct {
		Value string `json:"value"`
		Why   string `json:"why"`
	} `json:"refused"`
}

func readVectors(t *testing.T) vectors {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "..", "tests", "fixtures", "link.json"))
	if err != nil {
		t.Fatal(err)
	}
	var v vectors
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatal(err)
	}
	if len(v.Names) == 0 || len(v.Refused) == 0 {
		t.Fatal("link.json has an empty or missing section")
	}
	return v
}

var keyText = regexp.MustCompile(`^privkey:([0-9a-f]{64}),psk:([0-9a-f]{64})$`)

// publicOf is the public half of CYFR_LINK_KEY's private key, through
// crypto/ecdh.
func publicOf(t *testing.T, key string) string {
	t.Helper()
	m := keyText.FindStringSubmatch(key)
	if m == nil {
		t.Fatalf("%q is not privkey:<hex>,psk:<hex>", key)
	}
	b, _ := hex.DecodeString(m[1])
	k, err := ecdh.X25519().NewPrivateKey(b)
	if err != nil {
		t.Fatal(err)
	}
	return hex.EncodeToString(k.PublicKey().Bytes())
}

// Each row's public half is its private key's, and gives its name and
// address; every refused value is no public key.
func TestNameVectors(t *testing.T) {
	v := readVectors(t)
	for _, row := range v.Names {
		if got := publicOf(t, row.Key); got != row.Public {
			t.Errorf("%s: the key's public half is %s, want %s", row.Why, got, row.Public)
		}
		p, ok := ParsePublic(row.Public)
		if !ok {
			t.Errorf("%s: %s is refused", row.Why, row.Public)
			continue
		}
		if p.String() != row.Public {
			t.Errorf("%s: reads back as %s", row.Why, p.String())
		}
		if got := p.Name(); got != row.Name {
			t.Errorf("%s: name %s, want %s", row.Why, got, row.Name)
		}
		if got := p.Address(row.Port); got != row.Address {
			t.Errorf("%s: address %s, want %s", row.Why, got, row.Address)
		}
		if !PrivateHost(row.Name + ".localhost") {
			t.Errorf("%s: %s.localhost is not a private host", row.Why, row.Name)
		}
	}
	for _, row := range v.Refused {
		if _, ok := ParsePublic(row.Value); ok {
			t.Errorf("%s: %q is taken as a public key", row.Why, row.Value)
		}
	}
	if _, ok := ParsePublic(""); ok {
		t.Error("an empty value is taken as a public key")
	}
}

// A private host is a private name under localhost and nothing wider.
func TestPrivateHostIsThePrivateNameAlone(t *testing.T) {
	for _, host := range []string{
		"localhost", "127.0.0.1", "h-xeypbemm44chehc5", "x.localhost", "h-xeypbemm44chehc.localhost",
		"h-xeypbemm44chehc55.localhost", "h-XEYPBEMM44CHEHC5.localhost", "h-xeypbemm44chehc1.localhost",
		"a.h-xeypbemm44chehc5.localhost", "h-xeypbemm44chehc5.localhost.", "h-xeypbemm44chehc5.localhost.example.com",
	} {
		if PrivateHost(host) {
			t.Errorf("%q is taken as a private host", host)
		}
	}
}

// A minted key is the text the link service reads: a clamped private
// key whose public half is the one answered, and a pre-shared key that
// is not all zero; no two mints are one.
func TestMint(t *testing.T) {
	seen := map[string]bool{}
	for range 8 {
		key, public, err := Mint()
		if err != nil {
			t.Fatal(err)
		}
		m := keyText.FindStringSubmatch(key)
		if m == nil {
			t.Fatalf("%q is not privkey:<hex>,psk:<hex>", key)
		}
		private, _ := hex.DecodeString(m[1])
		if private[0]&7 != 0 || private[31]&128 != 0 || private[31]&64 == 0 {
			t.Errorf("the private key %x is not clamped", private)
		}
		if psk, _ := hex.DecodeString(m[2]); bytes.Equal(psk, make([]byte, 32)) {
			t.Error("the pre-shared key is all zero")
		}
		if got := publicOf(t, key); got != public.String() {
			t.Errorf("the public half is %s, the key's is %s", public, got)
		}
		if p, ok := ParsePublic(public.String()); !ok || p != public {
			t.Errorf("%s does not read back", public)
		}
		for _, part := range strings.Split(key, ",") {
			if seen[part] {
				t.Errorf("%s was minted twice", part)
			}
			seen[part] = true
		}
	}
}
