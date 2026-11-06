// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package shell

import (
	"crypto/sha256"
	"net/url"
	"strings"
	"testing"

	"github.com/cyfr/codex/internal/holder"
)

// The shell reads every recovery code of tests/fixtures/recovery_code.json
// as Prima.RecoveryCode reads it, and refuses each refused text with its
// reason.
func TestDecodeRecoveryCode_ReadsTheFixture(t *testing.T) {
	var v struct {
		Valid     []struct{ Code, Identifier, Secret, Name string } `json:"valid"`
		Spellings []struct{ Code, Text, Name string }               `json:"spellings"`
		Refused   []struct{ Error, Text, Name string }              `json:"refused"`
	}
	fixture(t, "recovery_code.json", &v)
	read := map[string][2]string{}
	for _, c := range v.Valid {
		id, secret, err := DecodeRecoveryCode(c.Code)
		if err != nil || id != c.Identifier || b64(secret) != c.Secret {
			t.Errorf("%s: %s %s %v", c.Name, id, b64(secret), err)
		}
		read[c.Code] = [2]string{id, b64(secret)}
	}
	for _, c := range v.Spellings {
		id, secret, err := DecodeRecoveryCode(c.Text)
		want, known := read[c.Code]
		if !known {
			want[0], _, _ = DecodeRecoveryCode(c.Code)
			_, s, _ := DecodeRecoveryCode(c.Code)
			want[1] = b64(s)
		}
		if err != nil || id != want[0] || b64(secret) != want[1] {
			t.Errorf("spelling %s: %v", c.Name, err)
		}
	}
	for _, c := range v.Refused {
		if _, _, err := DecodeRecoveryCode(c.Text); err == nil || err.Error() != c.Error {
			t.Errorf("refused %s: %v, want %s", c.Name, err, c.Error)
		}
	}
}

// The kit proof reproduces tests/fixtures/restore_kit.json's signed bytes
// and signature.
func TestKitProof_ReproducesTheFixture(t *testing.T) {
	var v struct {
		Kit   struct{ Seed, Public string } `json:"kit"`
		Valid struct {
			Fields map[string]string `json:"fields"`
			Proof  map[string]any    `json:"proof"`
			Signed string            `json:"signed"`
		} `json:"valid"`
	}
	fixture(t, "restore_kit.json", &v)
	seed, _ := unb64(v.Kit.Seed)
	f := v.Valid.Fields
	proof, err := KitProof(f["challenge"], f["identifier"], f["restore_id"], seed)
	signed, _ := Canonical(without(proof, "sig"))
	if err != nil || string(signed) != v.Valid.Signed || proof["sig"] != v.Valid.Proof["sig"] {
		t.Fatalf("kit proof %v (%v)\nsigned %s", proof, err, signed)
	}
}

// encodeRecoveryCode spells digest and secret as a recovery code, the
// server's composition, for tests alone.
func encodeRecoveryCode(digest, secret []byte) string {
	sum := sha256.Sum256(append(append(append([]byte(recoveryProtocol), 0), digest...), secret...))
	raw := append(append(append([]byte(nil), digest...), secret...), sum[:6]...)
	var b strings.Builder
	var held, bits uint
	for _, c := range raw {
		held = held<<8 | uint(c)
		bits += 8
		for bits >= 5 {
			bits -= 5
			b.WriteByte(recoveryAlphabet[(held>>bits)&31])
		}
	}
	return "CYFR-" + b.String()
}

// After a declared backup restore suspends the screen, its unlock is
// refused and the lock page offers the recovery code: a wrong code brings
// nothing back, the right one re-enables this screen's own client through
// the kit's restore credential and unlocks into Prism.
func TestReenable_BringsASuspendedScreenBackWithTheRecoveryCode(t *testing.T) {
	var v struct {
		Kit struct{ Seed, Public string } `json:"kit"`
	}
	fixture(t, "restore_kit.json", &v)
	seed, _ := unb64(v.Kit.Seed)
	code := encodeRecoveryCode(make([]byte, 32), seed)

	home := newFakeHome(t)
	b := newBox(t, home, t.TempDir())
	p := setUpAndOpen(t, home, b)
	b.post("/lock", nil)
	if strings.Contains(b.page(), `action="/kit"`) {
		t.Fatal("a screen in standing offers the recovery code")
	}
	home.mu.Lock()
	home.closeWith = 4403
	home.kitPublic, _ = unb64(v.Kit.Public)
	home.mu.Unlock()
	b.post("/unlock", url.Values{"secret": {p}})
	if page := b.page(); !strings.Contains(page, `action="/kit"`) {
		t.Fatalf("a suspended screen does not offer the recovery code:\n%s", page)
	}
	b.post("/kit", url.Values{"code": {code[:len(code)-1] + "0"}, "secret": {p}})
	if page := b.page(); len(home.reenabled) != 0 || !strings.Contains(page, "typo") {
		t.Fatalf("a mistyped code: reenabled %v\n%s", home.reenabled, page)
	}
	ticketOf(t, b.post("/kit", url.Values{"code": {strings.ToLower(code)}, "secret": {p}}), home)
	rec, _ := holder.Load(b.record)
	if len(home.reenabled) != 1 || home.reenabled[0] != rec.ClientID || home.heard(code) || home.heard(v.Kit.Seed) {
		t.Fatalf("reenabled %v for client %s, or the code reached CYFR", home.reenabled, rec.ClientID)
	}
}
