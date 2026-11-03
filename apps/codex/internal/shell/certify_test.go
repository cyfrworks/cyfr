// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package shell

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/cyfr/codex/internal/disk"
	"github.com/cyfr/codex/internal/holder"
)

const ownHome = "https://alice.example"

// remoteLine is a command line pairing with home for a person whose
// identity is kept at ownHome, which certify stands in for.
func remoteLine(t *testing.T, home *fakeHome, dir string, certify CertifyCall) *Shell {
	t.Helper()
	sh, err := New(Config{
		Address: home.address(), Client: home.srv.Client(), Record: filepath.Join(dir, "device.json"), DataDir: dir,
		Detect: func(string) disk.Report { return disk.Report{} }, Chip: func() bool { return false },
		Noun: "command line", Pair: home.pair, Certify: certify,
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { sh.Lock("") })
	return sh
}

// inviteRemote opens an invitation of this home for a remote person's
// device with this key digest.
func (h *fakeHome) inviteRemote(digest string) string {
	secret := h.invite(digest)
	h.mu.Lock()
	h.pairings[secret].remote = true
	h.mu.Unlock()
	return secret
}

// ownCertificate is what the person's own home issues for c: an identity's
// certificate for exactly that client, athanor, key and audience.
func ownCertificate(c Certification) map[string]any {
	now := time.Now().UnixMilli()
	return map[string]any{"protocol": "cyfr-device-cert/v1", "athanor": c.Athanor, "client_id": c.ClientID,
		"device_key": b64(c.DeviceKey), "audience": c.Audience, "issuer": ownHome, "not_before": now,
		"expires_at": now + 3_600_000, "sig": "sig",
		"subject": map[string]any{"kind": "identity", "identifier": "per_1", "key_epoch": "sha256:1"}}
}

// certifier is a person's own home certifying what it is asked, through
// edit, and keeping what it was asked.
type certifier struct {
	asked []Certification
	edit  func(map[string]any) map[string]any
}

func (c *certifier) call(_ context.Context, asked Certification) (Certified, error) {
	c.asked = append(c.asked, asked)
	cert := ownCertificate(asked)
	if c.edit != nil {
		cert = c.edit(cert)
	}
	raw, _ := json.Marshal(cert)
	return Certified{Issuer: ownHome, Certificate: raw}, nil
}

// A person whose identity is kept at another home pairs a command line
// here without a browser: this home answers what their home is to
// certify, the certification is obtained there (certify) for exactly this
// home, the athanor, the client it reserved and this key, and the
// completion carries that certificate with a proof under a new challenge.
// The record keeps that home's certificate and the device unlocks.
func TestPair_ARemotePersonIsCertifiedAtTheirOwnHome(t *testing.T) {
	home := newFakeHome(t)
	dir := t.TempDir()
	own := &certifier{}
	sh := remoteLine(t, home, dir, own.call)
	p := newSecret(t, sh)
	sh.Prepare(bytes.Clone(p), bytes.Clone(p))
	digest := sh.View().Digest
	secret := home.inviteRemote(digest)
	sh.Pair(t.Context(), home.address()+"/pair#code="+secret, bytes.Clone(p))

	if v := sh.View(); v.Page != PageUnlocked || !sh.Unlocked() {
		t.Fatalf("paired: page %s, notice %q", v.Page, v.Notice)
	}
	p0 := home.pairings[secret]
	if len(own.asked) != 1 || own.asked[0].Audience != home.address() || own.asked[0].Athanor != p0.athanor ||
		own.asked[0].ClientID != p0.client || KeyDigest(own.asked[0].DeviceKey) != digest || own.asked[0].Issuer != "" {
		t.Fatalf("asked to certify %+v", own.asked)
	}
	if len(home.shapes) != 0 {
		t.Errorf("pairing.complete was asked off the fixture's fields: %v", home.shapes)
	}
	if n := len(home.pairArgs); n != 3 || home.pairArgs[1]["certificate"] == nil || home.pairArgs[2]["certificate"] == nil {
		t.Fatalf("pairing.complete was asked %d times: %v", n, home.pairArgs)
	}
	rec, err := holder.Load(filepath.Join(dir, "device.json"))
	if err != nil || rec.ClientID != p0.client || readIssued(rec.Certificate).Issuer != ownHome {
		t.Fatalf("the record: %+v %v", rec, err)
	}
	if home.heard(string(p)) {
		t.Error("the home received the passphrase")
	}
}

// A certificate the person's home answered that certifies anything but
// exactly this device here, for an identity, by the home that answered it,
// is never presented: the pairing does not complete and the key is kept.
// So is a request to certify anything but this home's own reservation.
func TestPair_AnythingButThisDevicesCertificateIsNotUsed(t *testing.T) {
	for name, edit := range map[string]func(map[string]any) map[string]any{
		"another client": func(c map[string]any) map[string]any {
			c["client_id"] = "pcl_01a09fee-7c1d-7e2f-8a3b-4c5d6e7f8099"
			return c
		},
		"another athanor": func(c map[string]any) map[string]any {
			c["athanor"] = "ath_01a09fee-045b-770b-b745-a62792bb8799"
			return c
		},
		"another key":      func(c map[string]any) map[string]any { c["device_key"] = b64(make([]byte, 32)); return c },
		"another audience": func(c map[string]any) map[string]any { c["audience"] = "https://mallory.example"; return c },
		"another issuer":   func(c map[string]any) map[string]any { c["issuer"] = "https://mallory.example"; return c },
		"issued here":      func(c map[string]any) map[string]any { c["issuer"] = c["audience"]; return c },
		"a local subject": func(c map[string]any) map[string]any {
			c["subject"] = map[string]any{"kind": "local", "user_id": "usr_1"}
			return c
		},
		"no key epoch": func(c map[string]any) map[string]any {
			c["subject"] = map[string]any{"kind": "identity", "identifier": "per_1"}
			return c
		},
		"another protocol": func(c map[string]any) map[string]any { c["protocol"] = "cyfr-device-cert/v2"; return c },
	} {
		home := newFakeHome(t)
		own := &certifier{edit: edit}
		sh := remoteLine(t, home, t.TempDir(), own.call)
		p := newSecret(t, sh)
		sh.Prepare(bytes.Clone(p), bytes.Clone(p))
		secret := home.inviteRemote(sh.View().Digest)
		sh.Pair(t.Context(), home.address()+"/pair#code="+secret, bytes.Clone(p))
		v := sh.View()
		if v.Page != PageFinish || sh.Unlocked() || !strings.Contains(v.Notice, "Your key is kept") {
			t.Errorf("%s: page %s, notice %q", name, v.Page, v.Notice)
		}
		for _, args := range home.pairArgs {
			if args["certificate"] != nil {
				t.Errorf("%s: the certificate was presented", name)
			}
		}
	}

	for name, certify := range map[string]map[string]any{
		"another audience": {"audience": "https://mallory.example", "athanor": "ath_01a09fee-045b-770b-b745-a62792bb8798", "client_id": "pcl_01a09fee-7c1d-7e2f-8a3b-4c5d6e7f8050"},
		"an extra field":   {"audience": "", "athanor": "ath_01a09fee-045b-770b-b745-a62792bb8798", "client_id": "pcl_01a09fee-7c1d-7e2f-8a3b-4c5d6e7f8050", "device_key": "x"},
		"no client":        {"audience": "", "athanor": "ath_01a09fee-045b-770b-b745-a62792bb8798"},
	} {
		home := newFakeHome(t)
		if certify["audience"] == "" {
			certify["audience"] = home.address()
		}
		own := &certifier{}
		sh := remoteLine(t, home, t.TempDir(), own.call)
		sh.cfg.Pair = func(ctx context.Context, args map[string]any) (map[string]any, error) {
			return map[string]any{"challenge": map[string]any{}, "certify": certify}, nil
		}
		p := newSecret(t, sh)
		sh.Prepare(bytes.Clone(p), bytes.Clone(p))
		sh.Pair(t.Context(), home.address()+"/pair#code="+home.invite(sh.View().Digest), bytes.Clone(p))
		if len(own.asked) != 0 || sh.Unlocked() {
			t.Errorf("%s: the person's home was asked %+v", name, own.asked)
		}
	}
}

// A certification the person's home ended (their keys changed) is
// certified there again, by the same handoff, offered the home that
// certified it before; the replacement is kept and the device unlocks. A
// replacement for anything else is not kept.
func TestUnlock_AnEndedCertificationIsCertifiedAgainAtTheOwnHome(t *testing.T) {
	home := newFakeHome(t)
	issuer := newIssuerHome(t)
	dir := t.TempDir()
	own := &certifier{}
	sh := remoteLine(t, home, dir, own.call)
	p := newSecret(t, sh)
	sh.Prepare(bytes.Clone(p), bytes.Clone(p))
	sh.Pair(t.Context(), home.address()+"/pair#code="+home.inviteRemote(sh.View().Digest), bytes.Clone(p))
	sh.Lock("")

	// The certificate as the issuer's: half its life gone.
	path := filepath.Join(dir, "device.json")
	rec, _ := holder.Load(path)
	var c map[string]any
	_ = json.Unmarshal(rec.Certificate, &c)
	c["issuer"] = issuer.address()
	c["not_before"] = time.Now().Add(-50 * time.Minute).UnixMilli()
	c["expires_at"] = time.Now().Add(10 * time.Minute).UnixMilli()
	rec.Certificate, _ = json.Marshal(c)
	if err := rec.Save(path); err != nil {
		t.Fatal(err)
	}
	issuer.refuse = 409

	wrong := &certifier{edit: func(c map[string]any) map[string]any {
		c["client_id"] = "pcl_01a09fee-7c1d-7e2f-8a3b-4c5d6e7f8099"
		return c
	}}
	refused := remoteLine(t, home, dir, wrong.call)
	refused.Unlock(t.Context(), bytes.Clone(p))
	if refused.Unlocked() || len(wrong.asked) != 1 {
		t.Fatalf("a wrong re-certification unlocked: %q", refused.View().Notice)
	}
	if after, _ := holder.Load(path); readIssued(after.Certificate) != readIssued(rec.Certificate) {
		t.Fatalf("a wrong re-certification was kept: %s", after.Certificate)
	}

	again := &certifier{}
	sh = remoteLine(t, home, dir, again.call)
	sh.Unlock(t.Context(), bytes.Clone(p))
	if !sh.Unlocked() {
		t.Fatalf("re-certified: %q", sh.View().Notice)
	}
	if len(again.asked) != 1 || again.asked[0].Issuer != issuer.address() || again.asked[0].ClientID != rec.ClientID {
		t.Fatalf("asked %+v", again.asked)
	}
	if after, _ := holder.Load(path); readIssued(after.Certificate).Issuer != ownHome {
		t.Errorf("the replacement was not kept: %s", after.Certificate)
	}
}

// A certificate another home issued that this home will not take any more
// (4408, its keys rotated before half its life) is renewed at its issuer,
// never at this home, and the replacement connects.
func TestUnlock_ARefusedRemoteCertificateRenewsAtItsIssuer(t *testing.T) {
	home := newFakeHome(t)
	issuer := newIssuerHome(t)
	dir := t.TempDir()
	sh := remoteLine(t, home, dir, (&certifier{}).call)
	p := newSecret(t, sh)
	sh.Prepare(bytes.Clone(p), bytes.Clone(p))
	sh.Pair(t.Context(), home.address()+"/pair#code="+home.inviteRemote(sh.View().Digest), bytes.Clone(p))
	sh.Lock("")

	path := filepath.Join(dir, "device.json")
	rec, _ := holder.Load(path)
	var c map[string]any
	_ = json.Unmarshal(rec.Certificate, &c)
	c["issuer"] = issuer.address()
	old := time.Now().Add(time.Hour).UnixMilli()
	c["expires_at"] = old
	rec.Certificate, _ = json.Marshal(c)
	_ = rec.Save(path)
	home.stale = func(cert map[string]any) bool { return fmt.Sprint(cert["expires_at"]) == fmt.Sprint(old) }

	again := remoteLine(t, home, dir, (&certifier{}).call)
	again.Unlock(t.Context(), bytes.Clone(p))
	if !again.Unlocked() {
		t.Fatalf("unlock: %q", again.View().Notice)
	}
	if strings.Contains(home.received.String(), `"type":"renew"`) {
		t.Error("another home's certificate was renewed here")
	}
	if after, _ := holder.Load(path); readIssued(after.Certificate).ExpiresAt == old {
		t.Errorf("the replacement was not kept: %s", after.Certificate)
	}
}

// terminalVectors is tests/fixtures/confirmation_assertion.json's
// exchange.terminal: what a CYFR keeping none of the person's keys asks
// their own CYFR to certify, and what the certificate binds.
type terminalVectors struct {
	Exchange struct {
		Terminal struct {
			Certificate struct {
				Binds    []string `json:"binds"`
				Protocol string   `json:"protocol"`
				Subject  string   `json:"subject"`
			} `json:"certificate"`
			PairingComplete struct {
				Certify []string `json:"certify"`
			} `json:"pairing.complete"`
		} `json:"terminal"`
	} `json:"exchange"`
}

// The certify answer is read with exactly the vector's fields, and any
// one missing or one more refuses it; a certificate substituted in any
// field the vector says it binds, another protocol or another subject is
// not used.
func TestCertification_TheTerminalVectors(t *testing.T) {
	var v terminalVectors
	fixture(t, "confirmation_assertion.json", &v)
	tv := v.Exchange.Terminal
	b := Binding{Home: "https://hub.example", DeviceKey: testKey(t).pub}
	values := map[string]any{"audience": b.Home, "athanor": "ath_01a09fee-045b-770b-b745-a62792bb8798",
		"client_id": "pcl_01a09fee-7c1d-7e2f-8a3b-4c5d6e7f8091"}
	answer := map[string]any{}
	for _, f := range tv.PairingComplete.Certify {
		value, ok := values[f]
		if !ok {
			t.Fatalf("the vector's certify names %q, which this device does not read", f)
		}
		answer[f] = value
	}
	asked, err := certification(answer, b)
	if err != nil || len(answer) != len(values) {
		t.Fatalf("the vector's certify %v: %v", tv.PairingComplete.Certify, err)
	}
	for _, f := range tv.PairingComplete.Certify {
		short := map[string]any{}
		for k, v := range answer {
			if k != f {
				short[k] = v
			}
		}
		if _, err := certification(short, b); err == nil {
			t.Errorf("a certify without %s was read", f)
		}
	}
	extra := map[string]any{"device_key": b64(b.DeviceKey)}
	for k, v := range answer {
		extra[k] = v
	}
	if _, err := certification(extra, b); err == nil {
		t.Error("a certify with a field more was read")
	}

	good := ownCertificate(*asked)
	good["protocol"] = tv.Certificate.Protocol
	good["subject"].(map[string]any)["kind"] = tv.Certificate.Subject
	use := func(cert map[string]any) error {
		raw, _ := json.Marshal(cert)
		return Elsewhere(Certified{Issuer: ownHome, Certificate: raw}, *asked)
	}
	if err := use(good); err != nil {
		t.Fatalf("the vector's certificate was refused: %v", err)
	}
	for _, f := range tv.Certificate.Binds {
		bad := map[string]any{}
		for k, v := range good {
			bad[k] = v
		}
		bad[f] = map[string]any{"athanor": "ath_01a09fee-045b-770b-b745-a62792bb8799", "audience": "https://mallory.example",
			"client_id": "pcl_01a09fee-7c1d-7e2f-8a3b-4c5d6e7f8099", "device_key": b64(make([]byte, 32)),
			"issuer": "https://mallory.example"}[f]
		if bad[f] == nil {
			t.Fatalf("the vector binds %q, which this test does not substitute", f)
		}
		if err := use(bad); err == nil {
			t.Errorf("a certificate with another %s was used", f)
		}
	}
}
