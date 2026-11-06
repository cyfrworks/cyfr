// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package shell

import (
	"encoding/json"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/cyfr/codex/internal/account"
	"github.com/cyfr/codex/internal/disk"
	"github.com/cyfr/codex/internal/holder"
)

// memoryClients keeps a ClientRecord in memory, as a context does.
type memoryClients struct {
	mu sync.Mutex
	c  ClientRecord
}

func (m *memoryClients) Load() (ClientRecord, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.c, nil
}
func (m *memoryClients) Save(c ClientRecord) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.c = c
	return nil
}

// eventually is m's record once ok holds of it, within a second: a
// renewed certificate is kept on a goroutine of its own.
func (m *memoryClients) eventually(ok func(ClientRecord) bool) ClientRecord {
	deadline := time.Now().Add(time.Second)
	for {
		c, _ := m.Load()
		if ok(c) || time.Now().After(deadline) {
			return c
		}
		time.Sleep(5 * time.Millisecond)
	}
}

// commandLine is a device as cyfr login drives one: the shell of a
// command line, without a screen, its key in dir and its client at this
// CYFR in clients.
func commandLine(t *testing.T, home *fakeHome, dir string, clients *memoryClients, setup, invitation string) *Shell {
	t.Helper()
	sh, err := New(Config{
		Address: home.address(), Client: home.srv.Client(), Record: filepath.Join(dir, "key.json"), DataDir: dir,
		Clients: clients, Directory: home.accounts.URL(),
		Detect:     func(string) disk.Report { return disk.Report{} },
		Chip:       func() bool { return false },
		Noun:       "command line",
		Tokens:     func() string { return setup },
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

// enrolled makes a command line's key, has the account mira's device
// approve it, and unlocks it: its first hello, which the door admits as a
// member's. It answers the passphrase.
func enrolled(t *testing.T, home *fakeHome, sh *Shell) []byte {
	t.Helper()
	identifier, dev, _ := home.account(t, "mira")
	home.mu.Lock()
	home.members[identifier] = true
	home.mu.Unlock()
	p := newSecret(t, sh)
	sh.Make([]byte(string(p)), []byte(string(p)))
	v := sh.View()
	if v.Page != PageEnroll {
		t.Fatalf("a new key shows page %s", v.Page)
	}
	key, _ := account.UnB64(v.Key, 32, 32)
	home.approve(t, identifier, dev, key)
	sh.Enroll(t.Context(), "mira", time.Second)
	if v := sh.View(); v.Page != PageLocked {
		t.Fatalf("an approved key shows page %s: %s", v.Page, v.Notice)
	}
	sh.Unlock(t.Context(), []byte(string(p)))
	if !sh.Unlocked() {
		t.Fatalf("the enrolled command line did not unlock: %s", sh.View().Notice)
	}
	return p
}

// A command line added to an existing account: its key is made and
// written before anything is shown, its code and the account page that
// adds it are the key's, the wait for the account's log reads it until a
// device of the person's approves it, and the first unlock says hello
// with no capability, which the door decides; the client is kept and the
// next unlock connects under its certificate, saying no hello.
func TestEnroll_WaitsForTheApprovalThenSaysHello(t *testing.T) {
	old := pollEvery
	pollEvery = 10 * time.Millisecond
	t.Cleanup(func() { pollEvery = old })
	home := newFakeHome(t)
	identifier, dev, _ := home.account(t, "mira")
	home.mu.Lock()
	home.members[identifier] = true
	home.mu.Unlock()
	dir := t.TempDir()
	clients := &memoryClients{}
	sh := commandLine(t, home, dir, clients, "", "")
	p := newSecret(t, sh)
	sh.Make([]byte(string(p)), []byte(string(p)))
	rec, err := holder.Load(filepath.Join(dir, "key.json"))
	if err != nil || rec.Identifier != "" {
		t.Fatalf("the key record: %+v %v", rec, err)
	}
	v := sh.View()
	kid := account.Kid(rec.PublicKey)
	if v.Page != PageEnroll || v.Code != kid[7:23] || v.Key != b64(rec.PublicKey) ||
		v.AddURL != home.accounts.URL()+"/account/add#key="+b64(rec.PublicKey)+"&alg=ed25519&kind=device&code="+kid[7:23] {
		t.Fatalf("the enroll page: %+v", v)
	}

	sh.Enroll(t.Context(), "nobody", time.Second)
	if v := sh.View(); v.Page != PageEnroll || !strings.Contains(v.Notice, "No account is called @nobody") {
		t.Fatalf("an unknown name: %+v", v)
	}
	go func() {
		time.Sleep(50 * time.Millisecond)
		home.approve(t, identifier, dev, rec.PublicKey)
	}()
	sh.Enroll(t.Context(), "@mira", 5*time.Second)
	if v := sh.View(); v.Page != PageLocked {
		t.Fatalf("an approved key shows page %s: %s", v.Page, v.Notice)
	}
	rec, _ = holder.Load(filepath.Join(dir, "key.json"))
	if rec.Identifier != identifier || rec.Directory != home.accounts.URL() {
		t.Fatalf("the record names %s at %s", rec.Identifier, rec.Directory)
	}
	sh.Unlock(t.Context(), []byte(string(p)))
	hellos := home.hellosSeen()
	if !sh.Unlocked() || len(hellos) != 1 || hellos[0]["admission"] != nil || hellos[0]["kid"] != kid ||
		hellos[0]["display_name"] != "CYFR screen" {
		t.Fatalf("unlocked %v, hellos %v", sh.Unlocked(), hellos)
	}
	if c, _ := clients.Load(); c.ClientID != "pcl_1" || len(c.Certificate) == 0 {
		t.Fatalf("the client kept %+v", c)
	}
	sh.Lock("")

	again := commandLine(t, home, dir, clients, "", "")
	again.Unlock(t.Context(), []byte(string(p)))
	if !again.Unlocked() || len(home.hellosSeen()) != 1 {
		t.Fatalf("the second unlock: unlocked %v, %d hellos", again.Unlocked(), len(home.hellosSeen()))
	}
	if home.heard(string(p)) {
		t.Fatal("CYFR heard the passphrase")
	}
}

// A key no device approves within the wait is said not to be on the
// account yet, and the record names no account.
func TestEnroll_AnUnapprovedKeyWaitsNoLonger(t *testing.T) {
	old := pollEvery
	pollEvery = 10 * time.Millisecond
	t.Cleanup(func() { pollEvery = old })
	home := newFakeHome(t)
	home.account(t, "mira")
	sh := commandLine(t, home, t.TempDir(), &memoryClients{}, "", "")
	p := newSecret(t, sh)
	sh.Make([]byte(string(p)), []byte(string(p)))
	sh.Enroll(t.Context(), "mira", 50*time.Millisecond)
	if v := sh.View(); v.Page != PageEnroll || !strings.Contains(v.Notice, "not on @mira's account yet") {
		t.Fatalf("an unapproved key: %+v", v)
	}
}

// A new person joins by an invitation's code with an account made at this
// terminal: the recovery code is shown before anything is sent, then the
// account is made with this command line its first device and the hello
// brings the invitation's code; a code that admits no one leaves the
// command line locked, its account made.
func TestJoin_AnInvitationAdmitsTheAccountMadeHere(t *testing.T) {
	home := newFakeHome(t)
	code := "kWv9JM-SnFKinXOrSQ1Vln_O2Arkef-2GgvR8NdiTd4"
	home.invitationCode = code
	clients := &memoryClients{}
	sh := commandLine(t, home, t.TempDir(), clients, "", "wrong-code")
	p := newSecret(t, sh)
	sh.Setup(t.Context(), "ada", "", []byte(string(p)), []byte(string(p)))
	v := sh.View()
	if v.Page != PageRecovery || !strings.HasPrefix(v.RecoveryCode, "CYFR-") || home.accounts.Writes != 0 {
		t.Fatalf("the recovery page: %+v, %d writes", v, home.accounts.Writes)
	}
	sh.Saved(t.Context(), "")
	if v := sh.View(); v.Page != PageLocked || sh.Unlocked() || !strings.Contains(v.Notice, "does not admit your account") {
		t.Fatalf("a wrong code: page %s, notice %q", v.Page, v.Notice)
	}

	sh.cfg.Invitation = code
	sh.Unlock(t.Context(), []byte(string(p)))
	hellos := home.hellosSeen()
	last := hellos[len(hellos)-1]
	if !sh.Unlocked() || last["admission"].(map[string]any)["invitation"] != code {
		t.Fatalf("unlocked %v, hello %v", sh.Unlocked(), last)
	}
	if token, err := sh.Session(t.Context()); err != nil || token == "" {
		t.Fatalf("no session: %v", err)
	}
}

// A command line's own session is the unlock's reservation, its ticket
// spent at POST /device/session for the session's bearer: the lock of
// exactly that session is kept before the ticket is spent, and a lock
// submits it; a ticket is never spent twice.
func TestSession_SpendsTheTicketForTheBearerAndKeepsItsLock(t *testing.T) {
	home := newFakeHome(t)
	sh := commandLine(t, home, t.TempDir(), &memoryClients{}, "", "")
	enrolled(t, home, sh)

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

// A certificate the CYFR will not take any more (4408) is renewed on a new
// connection, proven by the key, and the new one kept; a certificate held
// for another key is not used, and the device says hello again.
func TestUnlock_RenewsAnExpiredCertificate(t *testing.T) {
	home := newFakeHome(t)
	clients := &memoryClients{}
	dir := t.TempDir()
	sh := commandLine(t, home, dir, clients, "", "")
	p := enrolled(t, home, sh)
	sh.Lock("")
	held, _ := clients.Load()
	home.mu.Lock()
	home.stale = func(cert map[string]any) bool { return true }
	home.mu.Unlock()

	sh.Unlock(t.Context(), []byte(string(p)))
	renewed := clients.eventually(func(c ClientRecord) bool { return string(c.Certificate) != string(held.Certificate) })
	if !sh.Unlocked() || string(renewed.Certificate) == string(held.Certificate) {
		t.Fatalf("unlocked %v; the certificate was not renewed: %s", sh.Unlocked(), sh.View().Notice)
	}
	sh.Lock("")
	home.mu.Lock()
	home.stale = nil
	home.mu.Unlock()

	var cert map[string]any
	_ = json.Unmarshal(renewed.Certificate, &cert)
	cert["kid"] = "sha256:" + strings.Repeat("1", 64)
	renewed.Certificate, _ = json.Marshal(cert)
	_ = clients.Save(renewed)
	hellos := len(home.hellosSeen())
	again := commandLine(t, home, dir, clients, "", "")
	again.Unlock(t.Context(), []byte(string(p)))
	if !again.Unlocked() || len(home.hellosSeen()) != hellos+1 {
		t.Fatalf("a certificate of another key: unlocked %v, %d hellos", again.Unlocked(), len(home.hellosSeen()))
	}
}

// A change drawn before the secret was asked (read through the command
// line's session) is confirmed by that secret alone: it opens the key
// afresh, a channel of its own reads the CYFR's request for the ref, and
// the request is answered only while the record is the one drawn; the
// device is locked again whatever the outcome. A wrong secret and a
// change that moved since it was drawn sign nothing.
func TestConfirmDrawn_SignsOnlyTheChangeDrawn(t *testing.T) {
	home := newFakeHome(t)
	sh := commandLine(t, home, t.TempDir(), &memoryClients{}, "", "")
	p := enrolled(t, home, sh)
	sh.Lock("")
	home.mu.Lock()
	home.pending["cnr_1"] = map[string]any{"ref": "cnr_1", "operation": "vault.create", "preview": map[string]any{"resource": "github"}}
	home.mu.Unlock()
	drawn := PendingConfirm{Ref: "cnr_1", Operation: "vault.create", Preview: map[string]any{"resource": "github"}}

	sh.ConfirmDrawn(t.Context(), drawn, []byte(otherPassphrase(t, string(p))))
	if v := sh.View(); len(home.confirmed) != 0 || !strings.Contains(v.Notice, "Nothing was signed") || sh.Unlocked() {
		t.Fatalf("a wrong secret: confirmed %d, notice %q, unlocked %v", len(home.confirmed), v.Notice, sh.Unlocked())
	}

	moved := drawn
	moved.Preview = map[string]any{"resource": "gitlab"}
	sh.ConfirmDrawn(t.Context(), moved, []byte(string(p)))
	if v := sh.View(); len(home.confirmed) != 0 || !strings.Contains(v.Notice, "not the one shown") || sh.Unlocked() {
		t.Fatalf("a moved change: confirmed %d, notice %q", len(home.confirmed), v.Notice)
	}

	sh.ConfirmDrawn(t.Context(), drawn, []byte(string(p)))
	if v := sh.View(); len(home.confirmed) != 1 || home.confirmed[0]["ref"] != "cnr_1" || v.Notice != "Confirmed on this command line." || sh.Unlocked() {
		t.Fatalf("confirmed %v, notice %q, unlocked %v", home.confirmed, v.Notice, sh.Unlocked())
	}
}
