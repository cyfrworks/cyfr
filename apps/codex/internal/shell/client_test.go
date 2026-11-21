// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package shell

import (
	"context"
	"encoding/json"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/cyfr/codex/internal/account"
	"github.com/cyfr/codex/internal/disk"
	"github.com/cyfr/codex/internal/holder"
)

// enrollNow and savedNow reach the shell's enrollment and its saved
// recovery code as the page does once the page's proof is checked
// (enrollByPage, asPage), with a key held since a setup allowed to open.
func enrollNow(s *Shell, ctx context.Context, name string, wait time.Duration) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.enroll(ctx, name, wait, true)
}

func savedNow(s *Shell, ctx context.Context, accepted string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.saved(ctx, accepted)
}

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

// device is a device's shell driven from a test, its key in dir and its
// client at this CYFR in clients.
func device(t *testing.T, home *fakeHome, dir string, clients *memoryClients, setup string) *Shell {
	t.Helper()
	sh, err := New(Config{
		Address: home.address(), Client: home.srv.Client(), Record: filepath.Join(dir, "key.json"), DataDir: dir,
		Clients: clients, Directory: home.accounts.URL(),
		Detect: func(string) disk.Report { return disk.Report{Root: disk.Unknown, Data: disk.Unknown} },
		Chip:   func() bool { return false },
		Tokens: func() string { return setup },
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

// enrolled makes a device's key, has the account mira's device
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
	enrollNow(sh, t.Context(), "mira", time.Second)
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
	sh := device(t, home, dir, clients, "")
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

	enrollNow(sh, t.Context(), "nobody", time.Second)
	if v := sh.View(); v.Page != PageEnroll || !strings.Contains(v.Notice, "No account is called @nobody") {
		t.Fatalf("an unknown name: %+v", v)
	}
	go func() {
		time.Sleep(50 * time.Millisecond)
		home.approve(t, identifier, dev, rec.PublicKey)
	}()
	enrollNow(sh, t.Context(), "@mira", 5*time.Second)
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

	again := device(t, home, dir, clients, "")
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
	sh := device(t, home, t.TempDir(), &memoryClients{}, "")
	p := newSecret(t, sh)
	sh.Make([]byte(string(p)), []byte(string(p)))
	enrollNow(sh, t.Context(), "mira", 50*time.Millisecond)
	if v := sh.View(); v.Page != PageEnroll || !strings.Contains(v.Notice, "not on @mira's account yet") {
		t.Fatalf("an unapproved key: %+v", v)
	}
}

// A certificate the CYFR will not take any more (4408) is renewed on a new
// connection, proven by the key, and the new one kept; a certificate held
// for another key is not used, and the device says hello again.
func TestUnlock_RenewsAnExpiredCertificate(t *testing.T) {
	home := newFakeHome(t)
	clients := &memoryClients{}
	dir := t.TempDir()
	sh := device(t, home, dir, clients, "")
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
	again := device(t, home, dir, clients, "")
	again.Unlock(t.Context(), []byte(string(p)))
	if !again.Unlocked() || len(home.hellosSeen()) != hellos+1 {
		t.Fatalf("a certificate of another key: unlocked %v, %d hellos", again.Unlocked(), len(home.hellosSeen()))
	}
}

// One account's device connects to one CYFR: the app's remote selection
// and a screen's local project share one record, and neither takes the
// other's place silently.
func TestTheClientRecordSelectsOneCYFR(t *testing.T) {
	f := ClientFile(filepath.Join(t.TempDir(), "client.json"))
	if err := f.SelectHome("https://cyfr.example.com", "https://cyfr.run"); err != nil {
		t.Fatal(err)
	}
	if err := f.Save(ClientRecord{Home: "https://cyfr.example.com", Directory: "https://cyfr.run", ClientID: "pcl_1", Certificate: json.RawMessage(`{"a":1}`)}); err != nil {
		t.Fatal(err)
	}
	if err := f.SelectHome("https://cyfr.example.com", "https://accounts.example.com"); err != nil {
		t.Fatal(err)
	}
	if c, _ := f.Load(); c.ClientID != "pcl_1" || c.Directory != "https://accounts.example.com" {
		t.Fatalf("a new directory for the same CYFR dropped its client: %+v", c)
	}
	if err := f.SelectProject("/home/ada/cyfr"); err == nil || !strings.Contains(err.Error(), "https://cyfr.example.com") {
		t.Fatalf("a local project took the app's CYFR's place: %v", err)
	}
	if err := f.SelectHome("https://other.example.com", "https://cyfr.run"); err != nil {
		t.Fatal(err)
	}
	if c, _ := f.Load(); c.ClientID != "" || len(c.Certificate) != 0 || c.Home != "https://other.example.com" {
		t.Fatalf("another CYFR kept the first one's client: %+v", c)
	}

	g := ClientFile(filepath.Join(t.TempDir(), "client.json"))
	for range 2 {
		if err := g.SelectProject("/home/ada/cyfr"); err != nil {
			t.Fatal(err)
		}
	}
	if err := g.SelectProject("/home/ada/other"); err == nil {
		t.Fatal("a second project took the first one's place")
	}
}
