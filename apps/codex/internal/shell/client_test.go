// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package shell

import (
	"context"
	"crypto/ed25519"
	"encoding/json"
	"errors"
	"net/http"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/cyfr/codex/internal/disk"
	"github.com/cyfr/codex/internal/holder"
)

// commandLine is a device as cyfr login drives one: the shell of a
// command line, without a screen, pairing through the home's
// pairing.complete.
func commandLine(t *testing.T, home *fakeHome, dir, invitation string) *Shell {
	t.Helper()
	sh, err := New(Config{
		Address: home.address(), Client: home.srv.Client(), Record: filepath.Join(dir, "device.json"), DataDir: dir,
		Detect:     func(string) disk.Report { return disk.Report{} },
		Chip:       func() bool { return false },
		Noun:       "command line",
		Pair:       home.pair,
		Invitation: invitation,
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { sh.Lock("") })
	return sh
}

func newSecret(t *testing.T, sh *Shell) []byte {
	t.Helper()
	p := sh.View().Passphrase
	if p == "" {
		t.Fatal("no passphrase shown for a machine without a chip")
	}
	return []byte(p)
}

// A new person joins by an invitation's code: the key is written before
// anything is sent, the code travels in X-Cyfr-Invitation on every entry,
// the completion carries their name and a recovery secret, and the home
// answers the certificate and the recovery code; the device is unlocked.
// A wrong code admits no one, and the record waits to finish.
func TestJoin_AnInvitationAdmitsANewPersonWithThisDevice(t *testing.T) {
	home := newFakeHome(t)
	home.invitationCode = "INVITE-1"
	dir := t.TempDir()
	home.recordPath = filepath.Join(dir, "device.json")

	wrong := commandLine(t, home, t.TempDir(), "")
	p := newSecret(t, wrong)
	wrong.Join(t.Context(), "INVITE-WRONG", "mira", []byte(string(p)), []byte(string(p)))
	if v := wrong.View(); v.Page != PageFinish || v.Admission != "invitation" || home.completes != 0 {
		t.Fatalf("a wrong invitation: page %s, admission %s, completes %d", v.Page, v.Admission, home.completes)
	}

	sh := commandLine(t, home, dir, "INVITE-1")
	p = newSecret(t, sh)
	sh.Join(t.Context(), "INVITE-1", "mira", []byte(string(p)), []byte(string(p)))
	v := sh.View()
	if v.Page != PageRecovery || v.Recovery == nil || v.Recovery.Name != "mira" || !sh.Unlocked() {
		t.Fatalf("joined: page %s, notice %q", v.Page, v.Notice)
	}
	if !slices.Equal(home.recordAtChallenge, []bool{true}) {
		t.Errorf("the key was not written before its challenge: %v", home.recordAtChallenge)
	}
	if home.heard(string(p)) {
		t.Error("the home received the passphrase")
	}
	rec, err := holder.Load(home.recordPath)
	if err != nil || rec.Admission != "invitation" || len(rec.Certificate) == 0 {
		t.Fatalf("the record: %+v %v", rec, err)
	}
}

// The open door admits a new person with no credential but the key's
// proof; a home whose door is shut refuses, naming the invitation it
// needs.
func TestJoin_TheOpenDoorAdmitsWithNoCredential(t *testing.T) {
	home := newFakeHome(t)
	sh := commandLine(t, home, t.TempDir(), "")
	p := newSecret(t, sh)
	sh.Join(t.Context(), "", "ada", []byte(string(p)), []byte(string(p)))
	if v := sh.View(); v.Page != PageFinish || v.Admission != "open" {
		t.Fatalf("a shut door: page %s", v.Page)
	}

	home.openDoor = true
	other := commandLine(t, home, t.TempDir(), "")
	p = newSecret(t, other)
	other.Join(t.Context(), "", "ada", []byte(string(p)), []byte(string(p)))
	if v := other.View(); v.Page != PageRecovery || !other.Unlocked() {
		t.Fatalf("the open door: page %s, notice %q", v.Page, v.Notice)
	}
}

// A completion whose answer is lost is recovered by resume, under the
// same invitation and proving the same key: the home commits one
// person, once, and a later run finishes with the record it kept, the
// invitation's code given again.
func TestJoin_ALostAnswerResumesUnderTheSameInvitationAndKey(t *testing.T) {
	home := newFakeHome(t)
	home.invitationCode = "INVITE-1"
	home.downComplete = true
	dir := t.TempDir()
	sh := commandLine(t, home, dir, "INVITE-1")
	p := newSecret(t, sh)
	sh.Join(t.Context(), "INVITE-1", "mira", []byte(string(p)), []byte(string(p)))
	if v := sh.View(); v.Page != PageFinish || home.completes != 0 {
		t.Fatalf("an unreached complete: page %s, completes %d", v.Page, home.completes)
	}
	sh.Lock("")

	home.dropComplete = true
	again := commandLine(t, home, dir, "INVITE-1")
	again.Finish(t.Context(), "mira", "INVITE-1", []byte(string(p)))
	if v := again.View(); v.Page != PageRecovery || home.completes != 1 || home.resumes != 1 {
		t.Fatalf("finished: page %s %q, completes %d, resumes %d", v.Page, v.Notice, home.completes, home.resumes)
	}
}

// pairOnBox pairs a command line: its key made and written, the
// invitation a device of the person's answered for that key's digest,
// then the link pasted.
func pairOnBox(t *testing.T, home *fakeHome, sh *Shell) []byte {
	t.Helper()
	p := newSecret(t, sh)
	sh.Prepare([]byte(string(p)), []byte(string(p)))
	v := sh.View()
	if v.Page != PageFinish || v.Admission != "pair" || v.Digest == "" {
		t.Fatalf("prepared: page %s, admission %s, notice %q", v.Page, v.Admission, v.Notice)
	}
	secret := home.invite(v.Digest)
	sh.Pair(t.Context(), home.address()+"/pair#code="+secret, []byte(string(p)))
	return p
}

// A command line pairs with the person's home by the invitation a device
// of theirs answered: its key is written before its code is shown, the
// completion names its holder and name with the key the invitation was
// opened for, and the certificate the home answers is kept; the device
// is then unlocked over its channel, and the passphrase reached no one.
func TestPair_CompletesWithTheHolderAndTheApprovedKey(t *testing.T) {
	home := newFakeHome(t)
	dir := t.TempDir()
	sh := commandLine(t, home, dir, "")
	p := pairOnBox(t, home, sh)

	if v := sh.View(); v.Page != PageUnlocked || !sh.Unlocked() {
		t.Fatalf("paired: page %s, notice %q", v.Page, v.Notice)
	}
	if len(home.pairArgs) != 2 || home.pairArgs[0]["holder_kind"] != "software" || home.pairArgs[0]["display_name"] == "" {
		t.Fatalf("pairing.complete was asked %v", home.pairArgs)
	}
	rec, err := holder.Load(filepath.Join(dir, "device.json"))
	if err != nil || rec.ClientID == "" || len(rec.Certificate) == 0 || rec.Admission != "pair" || rec.RequestID != "" {
		t.Fatalf("the record: %+v %v", rec, err)
	}
	if home.heard(string(p)) {
		t.Error("the home received the passphrase")
	}
}

// A pairing whose answer is lost is completed again with the same
// invitation and key, in the same run and in a later one from the record
// kept, and the home answers the client it committed; another key with
// the same invitation pairs nothing.
func TestPair_ALostAnswerFinishesWithTheSameKey(t *testing.T) {
	home := newFakeHome(t)
	home.dropPair = true
	sh := commandLine(t, home, t.TempDir(), "")
	pairOnBox(t, home, sh)
	if v := sh.View(); v.Page != PageUnlocked {
		t.Fatalf("a lost answer in the same run: page %s, notice %q", v.Page, v.Notice)
	}

	// Lost twice: the run ends, and the next run finishes from the record.
	home2 := newFakeHome(t)
	dir := t.TempDir()
	first := commandLine(t, home2, dir, "")
	p := newSecret(t, first)
	first.Prepare([]byte(string(p)), []byte(string(p)))
	secret := home2.invite(first.View().Digest)
	home2.dropPair = true
	failing := home2.pair
	calls := 0
	first.cfg.Pair = func(ctx context.Context, args map[string]any) (map[string]any, error) {
		calls++
		if calls == 3 {
			home2.mu.Lock()
			home2.dropPair = true
			home2.mu.Unlock()
		}
		return failing(ctx, args)
	}
	first.Pair(t.Context(), home2.address()+"/pair#code="+secret, []byte(string(p)))
	if v := first.View(); v.Page != PageFinish || !strings.Contains(v.Notice, "Your key is kept") {
		t.Fatalf("lost twice: page %s, notice %q", v.Page, v.Notice)
	}
	first.Lock("")
	later := commandLine(t, home2, dir, "")
	later.Pair(t.Context(), secret, []byte(string(p)))
	if v := later.View(); v.Page != PageUnlocked {
		t.Fatalf("the later run: page %s, notice %q", v.Page, v.Notice)
	}

	thief := commandLine(t, home2, t.TempDir(), "")
	q := newSecret(t, thief)
	thief.Prepare([]byte(string(q)), []byte(string(q)))
	thief.Pair(t.Context(), secret, []byte(string(q)))
	if v := thief.View(); v.Page != PageFinish {
		t.Fatalf("another key with the same invitation: page %s", v.Page)
	}
}

// What the person pastes is the link of this home's /pair, or its code
// alone: another home's link, another page or a code of another length
// is refused before anything is sent.
func TestInvitationSecret_ReadsThisHomesLinkOrItsCode(t *testing.T) {
	code := b64(make([]byte, 16))
	for text, want := range map[string]error{
		"https://alice.example/pair#code=" + code:        nil,
		"  " + code[:11] + " " + code[11:] + "\n":        nil,
		"https://ALICE.example/pair/#code=" + code:       nil,
		"https://mallory.example/pair#code=" + code:      ErrOtherHome,
		"https://alice.example/devices/add#code=" + code: ErrNotAnInvitation,
		"https://alice.example/pair#code=" + code + "AA": ErrNotAnInvitation,
		"https://alice.example/pair#certificate=" + code: ErrNotAnInvitation,
		b64(make([]byte, 32)):                            ErrNotAnInvitation,
	} {
		got, err := InvitationSecret("https://alice.example", text)
		if !errors.Is(err, want) || (want == nil && got != code) {
			t.Errorf("%q: %q, %v; want %v", text, got, err, want)
		}
	}
}

// The approve address is the home's /devices/add with the key's digest in
// the fragment, which no request carries.
func TestApproveURL_IsTheFixturesShape(t *testing.T) {
	var v struct {
		Exchange struct {
			Pairing struct {
				ApproveURL string `json:"approve_url"`
			} `json:"pairing"`
		} `json:"exchange"`
	}
	fixture(t, "device_unlock.json", &v)
	want := strings.NewReplacer("{home}", "https://alice.example", "{key_digest}", "DIGEST").Replace(v.Exchange.Pairing.ApproveURL)
	if got := ApproveURL("https://alice.example/", "DIGEST"); got != want {
		t.Errorf("approve address %q, want %q", got, want)
	}
}

// A command line's own session is the unlock's reservation, its ticket
// spent at POST /device/session for the session's bearer: the lock of
// exactly that session is kept before the ticket is spent, and a lock
// submits it; a ticket is never spent twice.
func TestSession_SpendsTheTicketForTheBearerAndKeepsItsLock(t *testing.T) {
	home := newFakeHome(t)
	sh := commandLine(t, home, t.TempDir(), "")
	pairOnBox(t, home, sh)

	token, err := sh.Session(t.Context())
	if err != nil || token != "TOKEN-ses_1" {
		t.Fatalf("session: %q, %v", token, err)
	}
	if len(sh.locks) != 1 {
		t.Fatalf("the shell holds %d lock proofs", len(sh.locks))
	}
	second, err := sh.Session(t.Context())
	if err != nil || second == token {
		t.Fatalf("a second session: %q, %v", second, err)
	}
	sh.Lock("")
	if !slices.Equal(home.locked, []string{"ses_1", "ses_2"}) {
		t.Errorf("locked %v, want both sessions", home.locked)
	}
	if _, err := sh.Session(t.Context()); err == nil {
		t.Error("a locked shell opened a session")
	}
}

// issuerHome is the person's own home, which certified a device for
// another home: POST /certify/v1/renew answers a renew challenge of its
// own for the stored certificate, then the replacement.
type issuerHome struct {
	*fakeHome
	replacement func(cert map[string]any) map[string]any
	refuse      int
}

func newIssuerHome(t *testing.T) *issuerHome {
	h := &issuerHome{fakeHome: newFakeHome(t)}
	h.srv.Config.Handler.(*http.ServeMux).HandleFunc("POST /certify/v1/renew", func(w http.ResponseWriter, r *http.Request) {
		m := h.body(r)
		h.mu.Lock()
		defer h.mu.Unlock()
		if h.refuse != 0 {
			reply(w, h.refuse, map[string]any{"code": "certification_ended"})
			return
		}
		cert, _ := m["certificate"].(map[string]any)
		proof, hasProof := m["proof"].(map[string]any)
		if !hasProof {
			reply(w, 200, map[string]any{"challenge": h.issue(map[string]any{"purpose": "renew", "athanor": cert["athanor"],
				"client_id": cert["client_id"], "device_key": cert["device_key"]})})
			return
		}
		if _, ok := h.verify(proof, "renew"); !ok {
			reply(w, 401, map[string]any{"code": "proof_refused"})
			return
		}
		next := map[string]any{}
		for k, v := range cert {
			next[k] = v
		}
		next["not_before"] = time.Now().UnixMilli()
		next["expires_at"] = time.Now().Add(time.Hour).UnixMilli()
		if h.replacement != nil {
			next = h.replacement(next)
		}
		reply(w, 200, map[string]any{"certificate": next})
	})
	return h
}

// A certificate another home issued is renewed at that home, proven by
// this device's key over that home's own renew challenge, and the
// replacement is kept only when it certifies the same client, athanor
// and key for the same home; an issuer that ended the certification
// renews nothing.
func TestRenewAtIssuer_RenewsAnotherHomesCertificateThere(t *testing.T) {
	issuer := newIssuerHome(t)
	b := Binding{Home: "https://hub.example", Athanor: "ath_01a09fee-045b-770b-b745-a62792bb8798",
		ClientID: "pcl_01a09fee-7c1d-7e2f-8a3b-4c5d6e7f8091", DeviceKey: testKey(t).pub}
	now := time.Now().UnixMilli()
	cert, _ := json.Marshal(map[string]any{"protocol": "cyfr-device-cert/v1", "athanor": b.Athanor, "client_id": b.ClientID,
		"device_key": b64(b.DeviceKey), "audience": b.Home, "issuer": issuer.address(), "not_before": now - 3_000_000, "expires_at": now + 600_000,
		"subject": map[string]any{"kind": "identity", "identifier": "per_1", "key_epoch": "sha256:1"}})

	got, err := RenewAtIssuer(t.Context(), issuer.srv.Client(), b, cert, testKey(t))
	if err != nil || readIssued(got).ExpiresAt <= now+600_000 {
		t.Fatalf("renewed: %s, %v", got, err)
	}

	for field, value := range map[string]any{"client_id": "pcl_01a09fee-7c1d-7e2f-8a3b-4c5d6e7f8092",
		"audience": "https://mallory.example", "device_key": b64(make([]byte, 32)), "athanor": "ath_01a09fee-045b-770b-b745-a62792bb8799"} {
		issuer.replacement = func(c map[string]any) map[string]any { c[field] = value; return c }
		if _, err := RenewAtIssuer(t.Context(), issuer.srv.Client(), b, cert, testKey(t)); !errors.Is(err, ErrRefused) {
			t.Errorf("a replacement naming another %s was kept: %v", field, err)
		}
	}
	issuer.replacement = nil

	for _, status := range []int{401, 403, 404, 409} {
		issuer.refuse = status
		if _, err := RenewAtIssuer(t.Context(), issuer.srv.Client(), b, cert, testKey(t)); !errors.Is(err, ErrCertificationEnded) {
			t.Errorf("%d: %v", status, err)
		}
	}
	issuer.refuse = 0

	local, _ := json.Marshal(map[string]any{"audience": b.Home, "issuer": b.Home})
	if _, err := RenewAtIssuer(t.Context(), issuer.srv.Client(), b, local, testKey(t)); err == nil {
		t.Error("a certificate this home issued was renewed elsewhere")
	}
}

// An unlock under a certificate another home issued, past half its life,
// renews it at that home first and keeps the replacement before the
// channel opens; one the issuer ended is not used.
func TestUnlock_RenewsAnotherHomesCertificateFirst(t *testing.T) {
	home := newFakeHome(t)
	issuer := newIssuerHome(t)
	dir := t.TempDir()
	sh := commandLine(t, home, dir, "")
	p := pairOnBox(t, home, sh)
	sh.Lock("")

	path := filepath.Join(dir, "device.json")
	rec, err := holder.Load(path)
	if err != nil {
		t.Fatal(err)
	}
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
	ended := commandLine(t, home, dir, "")
	ended.Unlock(t.Context(), []byte(string(p)))
	if ended.Unlocked() || !strings.Contains(ended.View().Notice, "ended this command line's certification") {
		t.Fatalf("an ended certification unlocked: %q", ended.View().Notice)
	}

	issuer.refuse = 0
	again := commandLine(t, home, dir, "")
	again.Unlock(t.Context(), []byte(string(p)))
	if !again.Unlocked() {
		t.Fatalf("unlock: %q", again.View().Notice)
	}
	rec, _ = holder.Load(path)
	if i := readIssued(rec.Certificate); i.ExpiresAt <= time.Now().Add(30*time.Minute).UnixMilli() {
		t.Errorf("the replacement was not kept: %s", rec.Certificate)
	}
}

// fixedKey is a test's device key, the same each time it is asked for.
type fixedKey struct {
	pub  []byte
	priv ed25519.PrivateKey
}

func (k fixedKey) Sign(msg []byte) []byte { return ed25519.Sign(k.priv, msg) }

func testKey(t *testing.T) fixedKey {
	t.Helper()
	priv := ed25519.NewKeyFromSeed(make([]byte, 32))
	return fixedKey{pub: []byte(priv.Public().(ed25519.PublicKey)), priv: priv}
}

// A new person's enrollment whose recovery code was never said saved
// unlocks, with the invitation's code given again, to that code alone:
// no session opens until it is said saved, and then one does.
func TestUnlock_AnUnsavedJoinShowsTheRecoveryCodeBeforeAnySession(t *testing.T) {
	home := newFakeHome(t)
	home.invitationCode = "INVITE-1"
	dir := t.TempDir()
	first := commandLine(t, home, dir, "INVITE-1")
	p := newSecret(t, first)
	first.Join(t.Context(), "INVITE-1", "mira", []byte(string(p)), []byte(string(p)))
	first.Lock("")

	again := commandLine(t, home, dir, "INVITE-1")
	again.Unlock(t.Context(), []byte(string(p)))
	if v := again.View(); v.Page != PageRecovery || v.Recovery == nil || v.Recovery.Code != "CYFR-TEST-RECOVERY-CODE" {
		t.Fatalf("the unsaved join unlocked to page %s, notice %q", v.Page, v.Notice)
	}
	if token, err := again.Session(t.Context()); err == nil || token != "" {
		t.Fatalf("a session opened before the code was saved: %q", token)
	}
	again.Saved(t.Context())
	if token, err := again.Session(t.Context()); err != nil || token == "" {
		t.Fatalf("no session once the code was saved: %q, %v", token, err)
	}
}
