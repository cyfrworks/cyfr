// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package shell

import (
	"bytes"
	"context"
	"crypto/ecdh"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"errors"
	"html"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/cyfr/codex/internal/account"
	"github.com/cyfr/codex/internal/account/accounttest"
	"github.com/cyfr/codex/internal/disk"
	"github.com/cyfr/codex/internal/holder"
)

// box is one screen under test: its shell, its pages and the CYFR it
// talks to.
type box struct {
	t        *testing.T
	home     *fakeHome
	shell    *Shell
	srv      *Server
	dir      string
	record   string
	restarts atomic.Int32
	// hidden hears each Restart, the hide a lock begins with.
	hidden chan struct{}
	now    atomic.Int64
	// proof is what the page's script keeps: the proof the last answer
	// that handed one over carried.
	proof string
}

// fixedDerivation puts back the derivation a person's key is made and
// opened under.
var fixedDerivation func()

// The shell's tests derive keys cheaply: their tables make and open a key a
// row, which at the fixed cost runs past the time Go and CI give a package.
func TestMain(m *testing.M) {
	fixedDerivation = holder.CheapDerivationForTests()
	os.Exit(m.Run())
}

// The shell makes a key, opens it and refuses a wrong passphrase under the
// fixed derivation too, on every system these tests run on.
func TestAKeyUnderTheFixedDerivationIsMadeOpenedAndRefused(t *testing.T) {
	t.Cleanup(func() { holder.CheapDerivationForTests() })
	fixedDerivation()
	home := newFakeHome(t)
	dir := t.TempDir()
	sh := device(t, home, dir, &memoryClients{}, "")
	p := enrolled(t, home, sh) // made, and opened by its first unlock
	rec, err := holder.Load(filepath.Join(dir, "key.json"))
	if err != nil {
		t.Fatal(err)
	}
	if b := rec.Software; b == nil || b.Time != 3 || b.MemoryKiB != 65536 || b.Threads != 4 || b.KeyLen != 32 {
		t.Fatalf("the key's record names %+v", b)
	}
	sh.Lock("")
	wrong := "abandon ability able about above zoo"
	sh.Unlock(t.Context(), []byte(wrong))
	if sh.Unlocked() || !strings.Contains(sh.View().Notice, "That is not this device's PIN or passphrase.") {
		t.Fatalf("a wrong passphrase: unlocked %v, %q", sh.Unlocked(), sh.View().Notice)
	}
	sh.Unlock(t.Context(), []byte(string(p)))
	if !sh.Unlocked() {
		t.Fatalf("the right passphrase did not open the key again: %q", sh.View().Notice)
	}
}

func newBox(t *testing.T, home *fakeHome, dir string) *box {
	t.Helper()
	return newBoxAt(t, home, dir, home.accounts.URL())
}

// newBoxAt is newBox at a CYFR whose account service is directory, its
// configuration changed by each of edit.
func newBoxAt(t *testing.T, home *fakeHome, dir, directory string, edit ...func(*Config)) *box {
	t.Helper()
	b := &box{t: t, home: home, dir: dir, record: filepath.Join(dir, "holder.json"), hidden: make(chan struct{}, 1)}
	b.now.Store(time.Now().UnixNano())
	cfg := Config{
		Address: home.address(), Client: home.srv.Client(), Record: b.record, DataDir: dir,
		Directory: directory,
		SetupToken: func(ctx context.Context) (string, http.RoundTripper) {
			if home.setupOpen(ctx) {
				return home.setupToken, nil
			}
			return "", nil
		},
		Restart: func() {
			b.restarts.Add(1)
			select {
			case b.hidden <- struct{}{}:
			default:
			}
		},
		Detect: func(string) disk.Report { return disk.Report{Root: disk.Encrypted, Data: disk.Unencrypted} },
		Now:    func() time.Time { return time.Unix(0, b.now.Load()) },
		Chip:   func() bool { return false },
	}
	for _, e := range edit {
		e(&cfg)
	}
	sh, err := New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	b.shell, b.srv = sh, &Server{Shell: sh, Work: NewWork(t.Context())}
	t.Cleanup(func() { sh.Lock("") })
	return b
}

func (b *box) do(method, path, origin string, fields url.Values) *httptest.ResponseRecorder {
	b.t.Helper()
	req := httptest.NewRequest(method, "http://"+Listen+path, strings.NewReader(fields.Encode()))
	if method == http.MethodPost {
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	}
	if origin != "" {
		req.Header.Set("Origin", origin)
	}
	w := httptest.NewRecorder()
	b.srv.ServeHTTP(w, req)
	return w
}

// post is a form of the shell's own page, as its script sends it: with
// the proof the page keeps, unless the form names one, and keeping the
// proof an answer hands over.
func (b *box) post(path string, fields url.Values) *httptest.ResponseRecorder {
	if fields == nil {
		fields = url.Values{}
	}
	if !fields.Has("proof") {
		fields.Set("proof", b.proof)
	}
	w := b.do(http.MethodPost, path, Origin, fields)
	if p := proofIn(w); p != "" {
		b.proof = p
	}
	return w
}

func (b *box) page() string {
	return html.UnescapeString(b.do(http.MethodGet, "/", "", nil).Body.String())
}

func body(w *httptest.ResponseRecorder) string { return html.UnescapeString(w.Body.String()) }

// otherPassphrase is a well-formed passphrase that is not p.
func otherPassphrase(t *testing.T, p string) string {
	for {
		q, err := holder.GeneratePassphrase()
		if err != nil {
			t.Fatal(err)
		}
		if q != p {
			return q
		}
	}
}

var codeShape = regexp.MustCompile(`<p class="code">([^<]+)</p>`)

// shown is the passphrase a setup without a chip shows once, in the
// answer to Show the passphrase.
func (b *box) shown() string {
	b.t.Helper()
	w := b.post("/passphrase", nil)
	m := codeShape.FindStringSubmatch(body(w))
	if m == nil {
		b.t.Fatalf("Show the passphrase answered %d:\n%s", w.Code, body(w))
	}
	return m[1]
}

// setUp sets the box up as name, through the pages, to the recovery page,
// whose answer hands over the proof and shows the code, and answers its
// passphrase.
func (b *box) setUp(name string) string {
	b.t.Helper()
	p := b.shown()
	w := b.post("/setup", url.Values{"name": {name}, "secret": {p}, "again": {p}})
	if w.Code != http.StatusOK || proofIn(w) == "" || !codeShape.MatchString(w.Body.String()) {
		b.t.Fatalf("setup answered %d %q:\n%s", w.Code, w.Header().Get("Location"), w.Body.String())
	}
	return p
}

// recovery is the recovery code the page holding the proof fetches.
func (b *box) recovery() string {
	b.t.Helper()
	m := codeShape.FindStringSubmatch(body(b.post("/recovery", nil)))
	if m == nil {
		b.t.Fatal("the page holding the proof is shown no recovery code")
	}
	return m[1]
}

var toShape = regexp.MustCompile(`data-to="([^"]*)"`)

// ticketOf is the ticket an answer sends the browser on with: a redirect,
// or the page an unlock answers, whose script goes on to it.
func ticketOf(t *testing.T, w *httptest.ResponseRecorder, home *fakeHome) string {
	t.Helper()
	loc := w.Header().Get("Location")
	if m := toShape.FindStringSubmatch(w.Body.String()); w.Code == http.StatusOK && m != nil {
		loc = html.UnescapeString(m[1])
	}
	prefix := home.address() + "/auth/device/complete#"
	if (w.Code != http.StatusSeeOther && w.Code != http.StatusOK) || !strings.HasPrefix(loc, prefix) {
		t.Fatalf("answered %d %q, want to go on to %s<ticket>", w.Code, loc, prefix)
	}
	return strings.TrimPrefix(loc, prefix)
}

// client is the box's entry in its list of CYFRs, as the file holds it.
func (b *box) client() ClientRecord {
	l, err := Homes(filepath.Join(b.dir, "homes.json")).Load()
	if err != nil {
		b.t.Fatal(err)
	}
	return l.Homes[b.shell.cfg.Address]
}

// A box without a chip refuses six digits and sets up with the generated
// passphrase given twice: its key is written and its account composed,
// and the recovery code shown, before anything is sent; once the code is
// said saved, the account is made with the box its first device and the
// name its own, the box says hello under the setup token, and the browser
// goes into Prism with a one-time ticket in the fragment. Neither CYFR nor
// the account service hears the passphrase.
func TestSetup_MakesTheAccountAndOpensPrism(t *testing.T) {
	home := newFakeHome(t)
	b := newBox(t, home, t.TempDir())

	if !strings.Contains(b.page(), "This device keeps its data unencrypted, whoever takes it reads everything: its CYFR data volume is not encrypted. "+
		"Keep this device where only people you trust can reach it, or install its system again with disk encryption turned on.") {
		t.Fatal("setup does not warn about the unencrypted data volume")
	}
	home.accounts.Down = true
	b.post("/setup", url.Values{"name": {"alice"}, "secret": {"123456"}, "again": {"123456"}})
	home.accounts.Down = false
	if page := b.page(); !strings.Contains(page, "needs the six-word passphrase") {
		t.Fatalf("six digits were not refused:\n%s", page)
	}
	if _, err := os.Stat(b.record); !os.IsNotExist(err) || home.heard("123456") || home.accounts.Writes != 0 {
		t.Fatal("a refused PIN made a key or reached anything")
	}

	p := b.setUp("alice")
	info, err := os.Stat(b.record)
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("the key record: %v %v", info, err)
	}
	page := body(b.post("/recovery", nil))
	code := b.recovery()
	if !strings.HasPrefix(code, "CYFR-") || !strings.Contains(page, "<svg") || !strings.Contains(page, `id="print"`) || !strings.Contains(page, "@alice") {
		t.Fatalf("the recovery page shows no code, QR or Print:\n%s", page)
	}
	if home.accounts.Writes != 0 || len(home.hellosSeen()) != 0 {
		t.Fatal("something was sent before the recovery code was said saved")
	}
	w := b.post("/saved", nil)
	if ticket := ticketOf(t, w, home); ticket != "TICKET-ses_1" {
		t.Fatalf("ticket %q", ticket)
	}
	if strings.Contains(b.page(), code) {
		t.Fatal("the recovery code is still shown after I saved it")
	}
	rec, _ := holder.Load(b.record)
	identifier, _, err := account.DecodeRecoveryCode(code)
	if err != nil || rec.Identifier != identifier || rec.Directory != home.accounts.URL() {
		t.Fatalf("the record names %s, the code %s (%v)", rec.Identifier, identifier, err)
	}
	st := home.accounts.State(t, identifier)
	if _, listed := st.Key(account.Kid(rec.PublicKey)); !listed || home.accounts.Holder("alice") != identifier {
		t.Fatal("the account does not list the box, or does not hold the name")
	}
	hellos := home.hellosSeen()
	if len(hellos) != 1 || hellos[0]["identifier"] != identifier || hellos[0]["holder_kind"] != "software" ||
		hellos[0]["display_name"] != "CYFR screen" || hellos[0]["admission"].(map[string]any)["setup"] != home.setupToken {
		t.Fatalf("hellos %v", hellos)
	}
	if c := b.client(); c.ClientID != "pcl_1" || len(c.Certificate) == 0 {
		t.Fatalf("the client kept %+v", c)
	}
	if got := home.opsSeen(); !slices.Equal(got, []string{"session.unlock", "session.unlock"}) {
		t.Fatalf("operations %v", got)
	}
	if home.heard(p) || home.heard(strings.ReplaceAll(p, " ", "+")) {
		t.Fatal("CYFR heard the passphrase")
	}
	if caps := home.capabilities; len(caps) == 0 || !slices.Equal(caps[0], []string{"root_encrypted", "data_unencrypted"}) {
		t.Fatalf("capabilities %v", caps)
	}
}

// A lost answer to a write is sent again by Try again with the same bytes:
// the account is made once.
func TestSetup_ALostAnswerLandsOnce(t *testing.T) {
	home := newFakeHome(t)
	b := newBox(t, home, t.TempDir())
	b.setUp("alice")
	home.accounts.Lose = 1
	b.post("/saved", nil)
	if page := b.page(); !strings.Contains(page, "Your account is not finished") || !strings.Contains(page, "could not be reached") {
		t.Fatalf("the lost answer says nothing:\n%s", page)
	}
	ticketOf(t, b.post("/saved", nil), home)
	rec, _ := holder.Load(b.record)
	if len(home.accounts.Log(rec.Identifier)) != 2 || home.accounts.Writes != 3 {
		t.Fatalf("the log holds %d entries after %d writes", len(home.accounts.Log(rec.Identifier)), home.accounts.Writes)
	}
}

// A box restarted while its account was being made finishes it from the
// recovery code alone, which re-derives the recovery key: the same
// account, never another.
func TestSetup_ARestartedBoxFinishesWithTheRecoveryCode(t *testing.T) {
	home := newFakeHome(t)
	dir := t.TempDir()
	b := newBox(t, home, dir)
	p := b.setUp("alice")
	code := b.recovery()
	home.accounts.Down = true
	b.post("/saved", nil)

	again := newBox(t, home, dir)
	if page := again.page(); !strings.Contains(page, "Finish your account") || !strings.Contains(page, "@alice") {
		t.Fatalf("the restarted box does not offer to finish:\n%s", page)
	}
	home.accounts.Down = false
	again.post("/resume", url.Values{"code": {"CYFR-0000"}})
	if !strings.Contains(again.page(), "not a recovery code") {
		t.Fatal("a wrong code was not said")
	}
	w := again.post("/resume", url.Values{"code": {strings.ToLower(code)}})
	if w.Code != http.StatusOK || proofIn(w) == "" || !strings.Contains(body(w), "CYFR is locked") {
		t.Fatalf("resume answered %d %q", w.Code, w.Header().Get("Location"))
	}
	if !strings.Contains(again.page(), "CYFR is locked") {
		t.Fatalf("the finished account does not ask the passphrase:\n%s", again.page())
	}
	ticketOf(t, again.post("/unlock", url.Values{"secret": {p}}), home)
	if hellos := home.hellosSeen(); len(hellos) != 1 || hellos[0]["admission"].(map[string]any)["setup"] != home.setupToken {
		t.Fatalf("the restarted box's hello brought no setup token: %v", hellos)
	}
	identifier, _, _ := account.DecodeRecoveryCode(code)
	if home.accounts.Holder("alice") != identifier {
		t.Fatal("the resumed account does not hold its name")
	}
	if _, err := os.Stat(filepath.Join(dir, "attempt.json")); !os.IsNotExist(err) {
		t.Fatal("the finished attempt is still kept")
	}
}

// A name someone took after it was checked asks for another: the account
// is made, and takes the next free name.
func TestSetup_ATakenNameAsksAnother(t *testing.T) {
	home := newFakeHome(t)
	b := newBox(t, home, t.TempDir())
	b.setUp("alice")
	home.accounts.Hold("alice", "per_"+strings.Repeat("0", 64))
	b.post("/saved", nil)
	if page := b.page(); !strings.Contains(page, "Someone holds the name @alice") || !strings.Contains(page, `action="/name"`) {
		t.Fatalf("the taken name asks nothing:\n%s", page)
	}
	ticketOf(t, b.post("/name", url.Values{"name": {"alice2"}}), home)
	rec, _ := holder.Load(b.record)
	if home.accounts.Holder("alice2") != rec.Identifier || len(home.accounts.Log(rec.Identifier)) != 2 {
		t.Fatal("the account was made twice, or took no name")
	}
}

// A name the registry keeps reserved reads as free until its claim is
// refused; then another name is asked, as for a taken one, and the
// account made once takes it.
func TestSetup_AReservedNameAsksAnother(t *testing.T) {
	home := newFakeHome(t)
	b := newBox(t, home, t.TempDir())
	b.setUp(accounttest.Reserved)
	b.post("/saved", nil)
	if page := b.page(); !strings.Contains(page, "The name @"+accounttest.Reserved+" is reserved") || !strings.Contains(page, `action="/name"`) {
		t.Fatalf("the reserved name asks nothing:\n%s", page)
	}
	ticketOf(t, b.post("/name", url.Values{"name": {"alice2"}}), home)
	rec, _ := holder.Load(b.record)
	if home.accounts.Holder("alice2") != rec.Identifier || len(home.accounts.Log(rec.Identifier)) != 2 {
		t.Fatal("the account was made twice, or took no name")
	}
}

// Where the account service names terms, setting up without accepting
// them makes nothing and shows them; accepted, the acceptance precedes the
// name's claim, and newer terms the registry asks for meanwhile are asked
// again before it.
func TestSetup_TheTermsAreAcceptedFirst(t *testing.T) {
	home := newFakeHome(t)
	home.accounts.Policy = &account.Policy{Version: "2026-10", URL: "https://cyfr.example/terms"}
	b := newBox(t, home, t.TempDir())
	b.page()
	shown := body(b.post("/passphrase", nil))
	if !strings.Contains(shown, "I accept the terms at https://cyfr.example/terms") {
		t.Fatalf("the setup page shows no terms:\n%s", shown)
	}
	p := codeShape.FindStringSubmatch(shown)[1]
	b.post("/setup", url.Values{"name": {"alice"}, "secret": {p}, "again": {p}})
	if _, err := os.Stat(b.record); !os.IsNotExist(err) || !strings.Contains(b.page(), "accept the terms") {
		t.Fatal("setting up without the terms made a key, or said nothing")
	}
	b.post("/setup", url.Values{"name": {"alice"}, "secret": {p}, "again": {p}, "accept": {"yes"}})
	home.accounts.Policy = &account.Policy{Version: "2026-11", URL: "https://cyfr.example/terms"}
	b.post("/saved", nil)
	if page := b.page(); !strings.Contains(page, "terms changed") || !strings.Contains(page, `name="accept"`) {
		t.Fatalf("newer terms are not asked:\n%s", page)
	}
	ticketOf(t, b.post("/saved", url.Values{"accept": {"yes"}}), home)
	rec, _ := holder.Load(b.record)
	if home.accounts.Accepted(rec.Identifier) != "2026-11" || home.accounts.Holder("alice") != rec.Identifier {
		t.Fatal("the newer terms were not accepted before the name")
	}
}

// A box added to an account of the person's: its key made under the
// passphrase, its code and the address that adds it shown, and once a
// device of theirs approved it, the account's name typed finds it listed;
// its first unlock says hello with no capability, though .env holds the
// setup token, and the CYFR's door decides.
func TestSetup_AnAccountOfYoursAddsThisBox(t *testing.T) {
	home := newFakeHome(t)
	identifier, dev, _ := home.account(t, "mira")
	home.mu.Lock()
	home.members[identifier] = true
	home.mu.Unlock()
	b := newBox(t, home, t.TempDir())
	p := b.shown()
	b.post("/make", url.Values{"secret": {p}, "again": {p}})
	rec, _ := holder.Load(b.record)
	kid := account.Kid(rec.PublicKey)
	page := b.page()
	addURL := home.accounts.URL() + "/account/add#key=" + b64(rec.PublicKey) + "&alg=ed25519&kind=device&code=" + kid[7:23]
	if !strings.Contains(page, kid[7:23]) || !strings.Contains(page, addURL) || strings.Contains(page, "cyfr device approve") || !strings.Contains(page, "<svg") {
		t.Fatalf("the enroll page:\n%s", page)
	}
	old := enrollWait
	enrollWait = 50 * time.Millisecond
	t.Cleanup(func() { enrollWait = old })
	b.post("/enroll", url.Values{"name": {"mira"}})
	if !strings.Contains(b.page(), "not on @mira's account yet") {
		t.Fatal("an unapproved box says nothing")
	}
	home.approve(t, identifier, dev, rec.PublicKey)
	b.post("/enroll", url.Values{"name": {"@mira"}})
	if !strings.Contains(b.page(), "CYFR is locked") {
		t.Fatalf("the approved box does not ask its passphrase:\n%s", b.page())
	}
	ticketOf(t, b.post("/unlock", url.Values{"secret": {p}}), home)
	if hellos := home.hellosSeen(); len(hellos) != 1 || hellos[0]["identifier"] != identifier || hellos[0]["admission"] != nil {
		t.Fatalf("hellos %v", hellos)
	}
	home.mu.Lock()
	used := home.setupUsed
	home.mu.Unlock()
	if used {
		t.Fatal("the setup token was spent by a box added to an existing account")
	}
}

// addedBox makes a box's key, adds it to identifier's account by dev, a
// device the account lists, and answers the box with its passphrase and
// key record, locked and never connected.
func addedBox(t *testing.T, home *fakeHome, identifier string, dev ed25519.PrivateKey) (*box, string, *holder.Record) {
	t.Helper()
	b := newBox(t, home, t.TempDir())
	p := b.shown()
	b.post("/make", url.Values{"secret": {p}, "again": {p}})
	rec, err := holder.Load(b.record)
	if err != nil {
		t.Fatal(err)
	}
	home.approve(t, identifier, dev, rec.PublicKey)
	b.post("/enroll", url.Values{"name": {"mira"}})
	if !strings.Contains(b.page(), "CYFR is locked") {
		t.Fatalf("the approved box is not locked:\n%s", b.page())
	}
	return b, p, rec
}

// removeKey removes pub from identifier's account, signed by dev, another
// device the account lists, as the account pages remove a key.
func removeKey(t *testing.T, home *fakeHome, identifier string, dev ed25519.PrivateKey, pub []byte) {
	t.Helper()
	state := home.accounts.State(t, identifier)
	signer := dev.Public().(ed25519.PublicKey)
	entry, err := account.Sign(account.Next(state, "remove_key", map[string]any{"kid": account.Kid(pub)},
		time.Now().UnixMilli(), account.Kid(signer)), dev)
	if err != nil {
		t.Fatal(err)
	}
	home.accounts.Append(t, identifier, entry)
}

// A key the account's log still lists unlocks as before: the screen reads
// the log first, shows no code, keeps the record's account and goes
// straight to the hello.
func TestCheckListed_AListedKeyGoesStraightToTheHello(t *testing.T) {
	home := newFakeHome(t)
	identifier, dev, _ := home.account(t, "mira")
	home.mu.Lock()
	home.members[identifier] = true
	home.mu.Unlock()
	b, p, rec := addedBox(t, home, identifier, dev)

	ticketOf(t, b.post("/unlock", url.Values{"secret": {p}}), home)
	if after, _ := holder.Load(b.record); after.Identifier != identifier {
		t.Fatalf("the record names %q after the unlock", after.Identifier)
	}
	if hellos := home.hellosSeen(); len(hellos) != 1 || hellos[0]["identifier"] != identifier || hellos[0]["kid"] != account.Kid(rec.PublicKey) {
		t.Fatalf("hellos %v", hellos)
	}
}

// A key removed from the account is said so at the screen's unlock,
// before the key is opened: the record names no account, the certificate
// the removal retired at this CYFR is dropped, nothing reaches CYFR, and
// the same key's code, the address that adds it and the command are shown
// again. Approved again and its name typed, the same key is listed, and
// the unlock says hello and connects.
func TestCheckListed_ARemovedKeyIsAddedAgainAndSaysHello(t *testing.T) {
	home := newFakeHome(t)
	identifier, dev, _ := home.account(t, "mira")
	home.mu.Lock()
	home.members[identifier] = true
	home.mu.Unlock()
	b, p, rec := addedBox(t, home, identifier, dev)
	ticketOf(t, b.post("/unlock", url.Values{"secret": {p}}), home)
	b.post("/lock", nil)
	if c := b.client(); c.ClientID != "pcl_1" || len(c.Certificate) == 0 {
		t.Fatalf("the first hello left %+v", c)
	}

	// Another device of the person's removes the key, and the CYFR, once
	// it reads the removal, retires the client.
	removeKey(t, home, identifier, dev, rec.PublicKey)
	home.revoke()

	ops := len(home.opsSeen())
	b.post("/unlock", url.Values{"secret": {p}})
	code := account.ShortCode(account.Kid(rec.PublicKey))
	page := b.page()
	if !strings.Contains(page, "Your account no longer lists this device's key.") || !strings.Contains(page, code) ||
		strings.Contains(page, "cyfr device approve") || !strings.Contains(page, "<svg") {
		t.Fatalf("the removed key's page:\n%s", page)
	}
	if after, _ := holder.Load(b.record); after.Identifier != "" || after.Directory != "" || !bytes.Equal(after.PublicKey, rec.PublicKey) {
		t.Fatalf("the record after the removal: %+v", after)
	}
	if c := b.client(); c.ClientID != "pcl_1" || len(c.Certificate) != 0 {
		t.Fatalf("the client after the removal: %+v", c)
	}
	if len(home.hellosSeen()) != 1 || len(home.opsSeen()) != ops || b.shell.Unlocked() {
		t.Fatal("the removed key reached CYFR")
	}

	home.approve(t, identifier, dev, rec.PublicKey)
	b.post("/enroll", url.Values{"name": {"mira"}})
	if page := b.page(); !strings.Contains(page, "CYFR is locked") {
		t.Fatalf("the key added again:\n%s", page)
	}
	ticketOf(t, b.post("/unlock", url.Values{"secret": {p}}), home)
	hellos := home.hellosSeen()
	if len(hellos) != 2 || hellos[1]["identifier"] != identifier || hellos[1]["kid"] != account.Kid(rec.PublicKey) || hellos[1]["admission"] != nil {
		t.Fatalf("hellos %v", hellos)
	}
	if after, _ := holder.Load(b.record); !bytes.Equal(after.PublicKey, rec.PublicKey) {
		t.Fatal("the key was made again")
	}
}

// A box added to an account of the person's says its first hello with
// the setup token while no one is set up on the CYFR, since its first
// person binds the installation whoever they are; on a CYFR someone is set
// up on it brings nothing, and the door decides.
func TestSetup_AnAddedBoxBringsTheTokenOnlyWhileNoOneIsSetUp(t *testing.T) {
	for _, open := range []bool{true, false} {
		home := newFakeHome(t)
		identifier, dev, _ := home.account(t, "mira")
		if !open {
			home.mu.Lock()
			home.members[identifier] = true
			home.mu.Unlock()
		}
		b := newBox(t, home, t.TempDir())
		p := b.shown()
		b.post("/make", url.Values{"secret": {p}, "again": {p}})
		rec, _ := holder.Load(b.record)
		home.approve(t, identifier, dev, rec.PublicKey)
		b.post("/enroll", url.Values{"name": {"mira"}})
		ticketOf(t, b.post("/unlock", url.Values{"secret": {p}}), home)
		hellos := home.hellosSeen()
		home.mu.Lock()
		used := home.setupUsed
		home.mu.Unlock()
		admission, _ := hellos[0]["admission"].(map[string]any)
		switch {
		case len(hellos) != 1:
			t.Fatalf("open %v: hellos %v", open, hellos)
		case open && (admission["setup"] != home.setupToken || !used):
			t.Fatalf("no one set up: the hello brought %v", hellos[0]["admission"])
		case !open && (hellos[0]["admission"] != nil || used):
			t.Fatalf("set up: the hello brought %v", hellos[0]["admission"])
		}
	}
}

// A box that makes its account on its setup page, on a CYFR someone is
// set up on and whose door is open, says its first hello with no
// capability: the setup token goes only while no one is set up, on every
// path, and the door admits the new person.
func TestSetup_ANewAccountOnASetUpCyfrBringsNoToken(t *testing.T) {
	home := newFakeHome(t)
	owner, _, _ := home.account(t, "owner")
	home.mu.Lock()
	home.members[owner] = true
	home.setupUsed = true
	home.openDoor = true
	home.mu.Unlock()
	b := newBox(t, home, t.TempDir())
	b.setUp("alice")
	answer := b.post("/saved", nil)
	hellos := home.hellosSeen()
	if len(hellos) != 1 || hellos[0]["admission"] != nil {
		t.Fatalf("hellos %v", hellos)
	}
	ticketOf(t, answer, home)
}

// setUpAndOpen sets a box up through to Prism and answers its passphrase.
func setUpAndOpen(t *testing.T, home *fakeHome, b *box) string {
	t.Helper()
	p := b.setUp("alice")
	ticketOf(t, b.post("/saved", nil), home)
	return p
}

// A lock hides the screen on the lock page, submits the pre-signed lock
// of each session the unlock reserved, redeemed or not, closes the
// channel and erases the key; a wrong passphrase after it is said and
// nothing reaches CYFR; the right one unlocks a new session.
func TestLock_RetiresEachSessionAndUnlockNeedsTheSecretAgain(t *testing.T) {
	home := newFakeHome(t)
	b := newBox(t, home, t.TempDir())
	p := setUpAndOpen(t, home, b)
	// A second ticket, never redeemed: a lock retires its reservation too.
	ticketOf(t, b.post("/open", nil), home)

	if w := b.do(http.MethodPost, "/lock", home.address(), nil); w.Code != http.StatusSeeOther {
		t.Fatalf("Prism's Lock answered %d", w.Code)
	}
	if !slices.Equal(home.locked, []string{"ses_1", "ses_2"}) || b.restarts.Load() != 1 || b.shell.Unlocked() {
		t.Fatalf("locked %v restarts %d unlocked %v", home.locked, b.restarts.Load(), b.shell.Unlocked())
	}
	if !strings.Contains(b.page(), "CYFR is locked") {
		t.Fatal("no lock page")
	}
	// A second lock tells the CYFR nothing more, and hides once more.
	b.post("/lock", nil)
	if len(home.locked) != 2 || b.restarts.Load() != 2 {
		t.Fatalf("a second lock did more, or did not hide: locked %v, %d hides", home.locked, b.restarts.Load())
	}

	ops := len(home.opsSeen())
	b.post("/unlock", url.Values{"secret": {otherPassphrase(t, p)}})
	if page := b.page(); !strings.Contains(page, "not this device") || len(home.opsSeen()) != ops {
		t.Fatalf("a wrong passphrase was not said, or reached CYFR:\n%s", page)
	}
	if ticket := ticketOf(t, b.post("/unlock", url.Values{"secret": {p}}), home); ticket != "TICKET-ses_3" {
		t.Fatalf("the unlock's ticket %q", ticket)
	}
}

// A standing the CYFR ends locks the box, saying why, and drops the
// certificate: the next unlock says hello again, with no setup token, and
// the CYFR's door decides.
func TestChannel_AnEndedStandingLocksTheBox(t *testing.T) {
	home := newFakeHome(t)
	b := newBox(t, home, t.TempDir())
	p := setUpAndOpen(t, home, b)
	home.revoke()
	deadline := time.Now().Add(5 * time.Second)
	for b.shell.Unlocked() && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if b.shell.Unlocked() || b.restarts.Load() != 1 || !strings.Contains(b.page(), "it was removed, CYFR does not admit your account") {
		t.Fatal("an ended standing did not lock the box")
	}
	// The record is written once the screen is hidden, as the lock ends.
	b.shell.Lock("")
	if c := b.client(); c.ClientID != "pcl_1" || len(c.Certificate) != 0 {
		t.Fatalf("the client kept %+v", c)
	}
	home.mu.Lock()
	home.members = map[string]bool{}
	home.mu.Unlock()
	b.post("/unlock", url.Values{"secret": {p}})
	if !strings.Contains(b.page(), "it was removed, CYFR does not admit your account") || b.shell.Unlocked() {
		t.Fatal("a box the door refuses unlocked")
	}
	home.mu.Lock()
	home.openDoor = true
	home.mu.Unlock()
	ticketOf(t, b.post("/unlock", url.Values{"secret": {p}}), home)
	hellos := home.hellosSeen()
	if len(hellos) != 3 || hellos[2]["admission"] != nil {
		t.Fatalf("hellos %v", hellos)
	}
	_ = websocket.StatusNormalClosure
}

// A restore suspends every device, so the box's certificate is refused at
// its first unlock after one: the screen says a restore may be why, drops
// the certificate, and the next unlock says hello again and is admitted.
func TestChannel_ACertificateARestoreSuspendedIsToldAndHelloedAgain(t *testing.T) {
	home := newFakeHome(t)
	b := newBox(t, home, t.TempDir())
	p := setUpAndOpen(t, home, b)
	b.post("/lock", nil)
	home.revoke()

	b.post("/unlock", url.Values{"secret": {p}})
	const told = "CYFR does not take this device now: it was removed, CYFR does not admit your account, " +
		"or CYFR was restored from a backup, which suspends every device. Unlocking it again asks CYFR again."
	if page := b.page(); !strings.Contains(page, told) || b.shell.Unlocked() {
		t.Fatalf("the refused certificate was not told as a restore may be why:\n%s", page)
	}
	if c := b.client(); c.ClientID != "pcl_1" || len(c.Certificate) != 0 {
		t.Fatalf("the client kept %+v", c)
	}
	ticketOf(t, b.post("/unlock", url.Values{"secret": {p}}), home)
	if hellos := home.hellosSeen(); len(hellos) != 2 {
		t.Fatalf("hellos %v", hellos)
	}
}

// A standing that ends with no announcement to the open channel is heard
// at the box's next report, as the CYFR reads the standing again at each
// one: the box locks, saying why, and drops the certificate.
func TestChannel_AStandingEndedUnannouncedEndsAtTheNextReport(t *testing.T) {
	oldEvery := reportEvery.Get()
	reportEvery.Set(50 * time.Millisecond)
	t.Cleanup(func() { reportEvery.Set(oldEvery) })
	home := newFakeHome(t)
	b := newBox(t, home, t.TempDir())
	setUpAndOpen(t, home, b)
	home.endStanding()
	deadline := time.Now().Add(5 * time.Second)
	for b.shell.Unlocked() && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if b.shell.Unlocked() || !strings.Contains(b.page(), "it was removed, CYFR does not admit your account") {
		t.Fatal("a standing ended unannounced did not lock the box at its next report")
	}
	// The record is written once the screen is hidden, as the lock ends.
	b.shell.Lock("")
	if c := b.client(); c.ClientID != "pcl_1" || len(c.Certificate) != 0 {
		t.Fatalf("the client kept %+v", c)
	}
}

// A change of CYFR's address leaves the box a certificate for its old
// address. The box does not present it, which the CYFR would answer with a
// challenge for that address, but drops it and says hello again with no
// capability, so the door admits it as it admits a terminal: refused, the
// certificate stays dropped; admitted, the box holds one for the address
// CYFR has now.
func TestChannel_ACertificateForAnotherAddressIsDroppedForAHello(t *testing.T) {
	home := newFakeHome(t)
	b := newBox(t, home, t.TempDir())
	p := setUpAndOpen(t, home, b)
	b.post("/lock", nil)
	held := b.client()
	var cert map[string]any
	if err := json.Unmarshal(held.Certificate, &cert); err != nil {
		t.Fatal(err)
	}
	cert["audience"] = "https://cyfr-old.example"
	raw, _ := json.Marshal(cert)
	if err := b.shell.cfg.Clients.Update(func(c *ClientRecord) bool { c.Certificate = raw; return true }); err != nil {
		t.Fatal(err)
	}
	home.mu.Lock()
	home.clients[held.ClientID].cert = cert
	identifier := home.clients[held.ClientID].identifier
	home.members = map[string]bool{}
	home.mu.Unlock()

	// The screen starts again after the change of address.
	b = newBox(t, home, b.dir)
	b.post("/unlock", url.Values{"secret": {p}})
	if c := b.client(); b.shell.Unlocked() || c.ClientID != held.ClientID || len(c.Certificate) != 0 {
		t.Fatalf("a box the door refuses: unlocked %v, client %+v", b.shell.Unlocked(), c)
	}

	home.mu.Lock()
	home.members[identifier] = true
	home.mu.Unlock()
	ticketOf(t, b.post("/unlock", url.Values{"secret": {p}}), home)
	hellos := home.hellosSeen()
	if len(hellos) != 3 || hellos[1]["admission"] != nil || hellos[2]["admission"] != nil {
		t.Fatalf("hellos %v", hellos)
	}
	var now map[string]any
	if err := json.Unmarshal(b.client().Certificate, &now); err != nil || now["audience"] != home.address() {
		t.Fatalf("the box holds %v (%v)", now, err)
	}
}

// A connection the network silently drops, the home still standing, locks
// the box at the next report: the shell's ping goes unanswered within its
// bound, the channel ends as unreachable, and the lock page says so, not
// that the screen idled. From the hide the lock begins with, the box is
// locked, though the silent CYFR is still being told.
func TestChannel_ASilentlyDroppedConnectionLocksTheBox(t *testing.T) {
	oldEvery, oldWithin := reportEvery.Get(), heardWithin.Get()
	reportEvery.Set(200 * time.Millisecond)
	heardWithin.Set(300 * time.Millisecond)
	t.Cleanup(func() { reportEvery.Set(oldEvery); heardWithin.Set(oldWithin) })
	home := newFakeHome(t)
	b := newBox(t, home, t.TempDir())
	setUpAndOpen(t, home, b)
	home.stall(t)
	select {
	case <-b.hidden:
	case <-time.After(30 * time.Second):
		t.Fatal("a dropped connection never locked the box")
	}
	unlocked := b.shell.Unlocked()
	page := b.page()
	if unlocked || !strings.Contains(page, "could not be reached") || strings.Contains(page, "five minutes") {
		t.Fatalf("a dropped connection did not lock the box as unreachable (unlocked=%v at the hide):\n%s", unlocked, page)
	}
}

// confirmable sets a box up, opens Prism and gives the home one pending
// confirmation.
func confirmable(t *testing.T) (*fakeHome, *box, string) {
	home := newFakeHome(t)
	b := newBox(t, home, t.TempDir())
	p := setUpAndOpen(t, home, b)
	home.mu.Lock()
	home.pending["cnr_1"] = map[string]any{"operation": "vault.create", "preview": map[string]any{"resource": "github", "athanor": "Household"}}
	home.mu.Unlock()
	return home, b, p
}

// Confirm on this device draws the home's own preview, never what the
// page sent, and needs the passphrase again even while unlocked: a wrong
// one, a cancel, a timeout or a preview changed at the home signs
// nothing; the right one signs the home's challenge for that ref.
func TestConfirm_DrawsTheHomesPreviewAndNeedsTheSecretAgain(t *testing.T) {
	home, b, p := confirmable(t)
	page := body(b.do(http.MethodGet, "/confirm?ref=cnr_1&preview=pay+mallory&challenge=x", "", nil))
	if !strings.Contains(page, "vault.create") || !strings.Contains(page, "github") || strings.Contains(page, "mallory") {
		t.Fatalf("the confirmation page:\n%s", page)
	}
	w := b.post("/confirm/decide", url.Values{"ref": {"cnr_1"}, "decision": {"confirm"}, "secret": {otherPassphrase(t, p)}})
	if len(home.confirmed) != 0 || !strings.Contains(body(w), "not this device") {
		t.Fatal("a wrong passphrase confirmed, or was not said")
	}
	w = b.post("/confirm/decide", url.Values{"ref": {"cnr_1"}, "decision": {"confirm"}, "secret": {p}})
	if len(home.confirmed) != 1 || home.confirmed[0]["ref"] != "cnr_1" || !strings.Contains(body(w), "Confirmed on this device") {
		t.Fatalf("confirmed %v", home.confirmed)
	}
	if home.heard(p) {
		t.Fatal("CYFR heard the passphrase")
	}
}

func TestConfirm_CancelTimeoutOrAChangedPreviewSignsNothing(t *testing.T) {
	home, b, p := confirmable(t)
	decide := func(decision string) string {
		return body(b.post("/confirm/decide", url.Values{"ref": {"cnr_1"}, "decision": {decision}, "secret": {p}}))
	}
	draw := func() { b.do(http.MethodGet, "/confirm?ref=cnr_1", "", nil) }

	draw()
	if page := decide("cancel"); len(home.confirmed) != 0 || !strings.Contains(page, "Nothing was confirmed") {
		t.Fatal("a cancel signed")
	}

	draw()
	b.now.Add(int64(61 * time.Second))
	if page := decide("confirm"); len(home.confirmed) != 0 || !strings.Contains(page, "waited too long") {
		t.Fatal("a timed-out confirmation signed")
	}

	draw()
	home.mu.Lock()
	home.pending["cnr_1"]["preview"] = map[string]any{"resource": "gitlab", "athanor": "Household"}
	home.mu.Unlock()
	if page := decide("confirm"); len(home.confirmed) != 0 || !strings.Contains(page, "not the one shown") {
		t.Fatal("a changed preview signed")
	}
}

// A locked box draws nothing and asks CYFR for nothing.
func TestConfirm_ALockedBoxFetchesNothing(t *testing.T) {
	home, b, _ := confirmable(t)
	b.post("/lock", nil)
	ops := len(home.opsSeen())
	w := b.do(http.MethodGet, "/confirm?ref=cnr_1", "", nil)
	if len(home.opsSeen()) != ops || !strings.Contains(body(w), "Unlock this device first") {
		t.Fatal("a locked box fetched a confirmation")
	}
}

// newPasskey is a passkey as a browser makes one: a P-256 point,
// uncompressed, and a random credential id.
func newPasskey(t *testing.T) account.Key {
	t.Helper()
	priv, err := ecdh.P256().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	pub := priv.PublicKey().Bytes()
	cid := make([]byte, 16)
	_, _ = rand.Read(cid)
	return account.Key{Kid: account.Kid(pub), Alg: "es256", Kind: "passkey", Pub: pub, CredentialID: cid}
}

// waitingPasskey is the record pairing.waiting lists for key under ref.
func waitingPasskey(ref string, key account.Key) map[string]any {
	return map[string]any{"ref": ref, "code": account.ShortCode(key.Kid), "key": key.Map(), "asked_at": "2026-11-14T12:00:00Z"}
}

// passkeyAsked sets a box up through to Prism, its account's only key the
// box's own, and has the CYFR hold one passkey a browser asks to add under
// pkw_1. It answers the box's passphrase, its key record and the passkey.
func passkeyAsked(t *testing.T) (*fakeHome, *box, string, *holder.Record, account.Key) {
	t.Helper()
	home := newFakeHome(t)
	b := newBox(t, home, t.TempDir())
	p := setUpAndOpen(t, home, b)
	rec, err := holder.Load(b.record)
	if err != nil {
		t.Fatal(err)
	}
	if st := home.accounts.State(t, rec.Identifier); len(st.Keys) != 1 || st.Keys[0].Kid != account.Kid(rec.PublicKey) {
		t.Fatalf("the account's keys are not the box's alone: %+v", st.Keys)
	}
	key := newPasskey(t)
	home.mu.Lock()
	home.waiting["pkw_1"] = waitingPasskey("pkw_1", key)
	home.mu.Unlock()
	return home, b, p, rec, key
}

func keysOf(keys []account.Key) string {
	maps := make([]any, len(keys))
	for i, k := range keys {
		maps[i] = k.Map()
	}
	return jcsString(maps)
}

// A browser asks to add a passkey to an account whose only key is the
// box's: the box draws the request from CYFR and shows the code it derives
// from the key, and its passphrase, typed again, adds the passkey to the
// account's log by an add_key the box's key signs. The window says so and
// closes, and CYFR never hears the passphrase.
func TestPasskey_TheBoxAddsTheWaitingPasskeyToItsAccount(t *testing.T) {
	home, b, p, rec, key := passkeyAsked(t)
	before := home.accounts.State(t, rec.Identifier)

	page := body(b.do(http.MethodGet, "/passkey?ref=pkw_1", "", nil))
	if !strings.Contains(page, "<h1>Add a passkey to your account</h1>") ||
		!strings.Contains(page, "A browser asks to add a passkey to your account. Approve it only if that browser shows this same code:") ||
		!strings.Contains(page, `<p class="code">`+account.ShortCode(key.Kid)+`</p>`) || !strings.Contains(page, `name="ref" value="pkw_1"`) {
		t.Fatalf("the passkey page:\n%s", page)
	}
	if !strings.Contains(page, `name="key" value="`+keyDigest(key)+`"`) {
		t.Fatalf("the form does not carry the key it shows:\n%s", page)
	}
	page = body(b.post("/passkey/decide", url.Values{"ref": {"pkw_1"}, "key": {keyDigest(key)}, "decision": {"approve"}, "secret": {p}}))
	if !strings.Contains(page, "Added to your account. The browser that asked signs in with its passkey now.") || !strings.Contains(page, "<h1>Done</h1>") {
		t.Fatalf("the answer:\n%s", page)
	}
	after := home.accounts.State(t, rec.Identifier)
	if got, want := keysOf(after.Keys), keysOf([]account.Key{before.Keys[0], key}); got != want {
		t.Fatalf("the account lists\n %s\nwant %s", got, want)
	}
	log := home.accounts.Log(rec.Identifier)
	last := log[len(log)-1].(map[string]any)
	if last["kind"] != "add_key" || last["signer"] != account.Kid(rec.PublicKey) || after.Seq != before.Seq+1 {
		t.Fatalf("the last entry %v", last)
	}
	if home.heard(p) || home.heard(strings.ReplaceAll(p, " ", "+")) {
		t.Fatal("CYFR heard the passphrase")
	}
}

// A request the person did not approve adds nothing: a decision with no
// request drawn, a cancel, a request that waited past its minute, one CYFR
// no longer holds or holds with another key under the same ref, and a
// wrong passphrase, which leaves the request drawn: the right one then
// adds it, once.
func TestPasskey_AnUnapprovedRequestAddsNothing(t *testing.T) {
	home, b, p, rec, key := passkeyAsked(t)
	entries := len(home.accounts.Log(rec.Identifier))
	decide := func(decision, secret string) string {
		t.Helper()
		page := body(b.post("/passkey/decide", url.Values{"ref": {"pkw_1"}, "key": {keyDigest(key)}, "decision": {decision}, "secret": {secret}}))
		if n := len(home.accounts.Log(rec.Identifier)); n != entries {
			t.Fatalf("the log holds %d entries, %d before:\n%s", n, entries, page)
		}
		return page
	}
	draw := func() {
		t.Helper()
		if page := body(b.do(http.MethodGet, "/passkey?ref=pkw_1", "", nil)); !strings.Contains(page, account.ShortCode(key.Kid)) {
			t.Fatalf("not drawn:\n%s", page)
		}
	}
	hold := func(k account.Key) {
		home.mu.Lock()
		home.waiting["pkw_1"] = waitingPasskey("pkw_1", k)
		home.mu.Unlock()
	}

	if page := decide("approve", p); strings.Contains(page, "Added") || strings.Contains(page, account.ShortCode(key.Kid)) {
		t.Fatalf("a decision with nothing drawn:\n%s", page)
	}

	draw()
	if page := decide("cancel", p); !strings.Contains(page, "Nothing was added.") || !strings.Contains(page, "<h1>Done</h1>") {
		t.Fatalf("a cancel:\n%s", page)
	}

	draw()
	b.now.Add(int64(61 * time.Second))
	if page := decide("approve", p); !strings.Contains(page, "That request waited too long, so nothing was added. Approve it again from Your devices.") {
		t.Fatalf("a request past its minute:\n%s", page)
	}

	draw()
	home.mu.Lock()
	delete(home.waiting, "pkw_1")
	home.mu.Unlock()
	if page := decide("approve", p); !strings.Contains(page, "CYFR no longer holds that request, so nothing was added.") {
		t.Fatalf("a request CYFR no longer holds:\n%s", page)
	}

	hold(key)
	draw()
	hold(newPasskey(t))
	if page := decide("approve", p); !strings.Contains(page, "CYFR no longer holds that request, so nothing was added.") {
		t.Fatalf("a request whose key changed at CYFR:\n%s", page)
	}

	hold(key)
	draw()
	if page := decide("approve", otherPassphrase(t, p)); !strings.Contains(page, "That is not this device's PIN or passphrase.") ||
		!strings.Contains(page, `<p class="code">`+account.ShortCode(key.Kid)+`</p>`) {
		t.Fatalf("a wrong passphrase:\n%s", page)
	}
	page := body(b.post("/passkey/decide", url.Values{"ref": {"pkw_1"}, "key": {keyDigest(key)}, "decision": {"approve"}, "secret": {p}}))
	if _, listed := home.accounts.State(t, rec.Identifier).Key(key.Kid); !listed || len(home.accounts.Log(rec.Identifier)) != entries+1 ||
		!strings.Contains(page, "<h1>Done</h1>") {
		t.Fatalf("the right passphrase after a wrong one:\n%s", page)
	}
}

// A box locked since the draw asks CYFR for nothing and adds nothing: it
// says to unlock first.
func TestPasskey_ALockedBoxAddsNothing(t *testing.T) {
	home, b, p, rec, _ := passkeyAsked(t)
	b.do(http.MethodGet, "/passkey?ref=pkw_1", "", nil)
	b.post("/lock", nil)
	entries, ops := len(home.accounts.Log(rec.Identifier)), len(home.opsSeen())
	says := "Unlock this device first, then approve the passkey again from Your devices."
	drawn := body(b.do(http.MethodGet, "/passkey?ref=pkw_1", "", nil))
	decided := body(b.post("/passkey/decide", url.Values{"ref": {"pkw_1"}, "decision": {"approve"}, "secret": {p}}))
	if !strings.Contains(drawn, says) || !strings.Contains(decided, says) || len(home.opsSeen()) != ops ||
		len(home.accounts.Log(rec.Identifier)) != entries {
		t.Fatalf("a locked box: the draw\n%s\nthe decision\n%s", drawn, decided)
	}
}

// A page approves only the key it showed. Drawn again under the same ref
// with another key, as a second window opened from Your devices does, the
// first window's approval adds nothing, says the request changed, and
// opens no key: even a wrong passphrase there is not tried. The window
// showing the new key then adds that one.
func TestPasskey_AnEarlierPageApprovesOnlyTheKeyItShowed(t *testing.T) {
	home, b, p, rec, first := passkeyAsked(t)
	shown := body(b.do(http.MethodGet, "/passkey?ref=pkw_1", "", nil))
	if !strings.Contains(shown, account.ShortCode(first.Kid)) {
		t.Fatalf("the first key is not drawn:\n%s", shown)
	}
	entries := len(home.accounts.Log(rec.Identifier))
	second := newPasskey(t)
	home.mu.Lock()
	home.waiting["pkw_1"] = waitingPasskey("pkw_1", second)
	home.mu.Unlock()
	if again := body(b.do(http.MethodGet, "/passkey?ref=pkw_1", "", nil)); !strings.Contains(again, account.ShortCode(second.Kid)) {
		t.Fatalf("the second key is not drawn:\n%s", again)
	}

	changed := "That request changed since this window showed its code, so nothing was added. Approve it again from Your devices."
	for _, secret := range []string{otherPassphrase(t, p), p} {
		page := body(b.post("/passkey/decide", url.Values{"ref": {"pkw_1"}, "key": {keyDigest(first)}, "decision": {"approve"}, "secret": {secret}}))
		if !strings.Contains(page, changed) || strings.Contains(page, "That is not this device's PIN or passphrase.") ||
			len(home.accounts.Log(rec.Identifier)) != entries {
			t.Fatalf("the earlier page's approval:\n%s", page)
		}
	}

	page := body(b.post("/passkey/decide", url.Values{"ref": {"pkw_1"}, "key": {keyDigest(second)}, "decision": {"approve"}, "secret": {p}}))
	st := home.accounts.State(t, rec.Identifier)
	_, firstListed := st.Key(first.Kid)
	_, secondListed := st.Key(second.Kid)
	if firstListed || !secondListed || len(home.accounts.Log(rec.Identifier)) != entries+1 || !strings.Contains(page, "<h1>Done</h1>") {
		t.Fatalf("the second page's approval lists the first %v, the second %v:\n%s", firstListed, secondListed, page)
	}
}

// From the decision's last read of the request to its signature the shell
// holds its one lock: a draw of another key under the same ref that
// arrives meanwhile waits, and the key signed is the one the page showed.
func TestPasskey_ARedrawDuringTheDecisionWaitsForIt(t *testing.T) {
	home, b, p, rec, first := passkeyAsked(t)
	b.do(http.MethodGet, "/passkey?ref=pkw_1", "", nil)
	second := newPasskey(t)
	redrawn := make(chan string, 1)
	home.onWaiting = func(ref string) {
		home.onWaiting = nil
		home.waiting[ref] = waitingPasskey(ref, second)
		go func() { redrawn <- body(b.do(http.MethodGet, "/passkey?ref="+ref, "", nil)) }()
	}
	page := body(b.post("/passkey/decide", url.Values{"ref": {"pkw_1"}, "key": {keyDigest(first)}, "decision": {"approve"}, "secret": {p}}))
	st := home.accounts.State(t, rec.Identifier)
	_, firstListed := st.Key(first.Kid)
	_, secondListed := st.Key(second.Kid)
	if !firstListed || secondListed || !strings.Contains(page, "Added to your account.") {
		t.Fatalf("the decision lists the shown key %v, the redrawn %v:\n%s", firstListed, secondListed, page)
	}
	if again := <-redrawn; !strings.Contains(again, account.ShortCode(second.Kid)) {
		t.Fatalf("the redraw, once the decision ended:\n%s", again)
	}
}

// dropAppendAnswers keeps every request's effect and loses the answer to
// each append, as a link that fails on the way back does.
type dropAppendAnswers struct{ base http.RoundTripper }

func (d dropAppendAnswers) RoundTrip(r *http.Request) (*http.Response, error) {
	resp, err := d.base.RoundTrip(r)
	if err == nil && r.Method == http.MethodPost && strings.HasSuffix(r.URL.Path, "/append") {
		resp.Body.Close()
		return nil, errors.New("the answer was lost")
	}
	return resp, err
}

// An approval whose answers were lost does not know whether the passkey
// was added, and says so with where to look; one whose account could not
// be read sent nothing, and says nothing was added.
func TestPasskey_ALostAnswerIsNotSaidToAddNothing(t *testing.T) {
	home, b, p, rec, key := passkeyAsked(t)
	b.do(http.MethodGet, "/passkey?ref=pkw_1", "", nil)
	client := http.Client{Transport: dropAppendAnswers{base: http.DefaultTransport}}
	if b.shell.cfg.Client != nil && b.shell.cfg.Client.Transport != nil {
		client.Transport = dropAppendAnswers{base: b.shell.cfg.Client.Transport}
	}
	b.shell.cfg.Client = &client
	page := body(b.post("/passkey/decide", url.Values{"ref": {"pkw_1"}, "key": {keyDigest(key)}, "decision": {"approve"}, "secret": {p}}))
	_, listed := home.accounts.State(t, rec.Identifier).Key(key.Kid)
	if !listed || strings.Contains(page, "Nothing was added") || strings.Contains(page, "was not added") ||
		!strings.Contains(page, "Your account's answer did not arrive, so this device does not know whether the passkey was added. "+
			"Sign in with it in the browser that asked, or look at your account's devices page, which lists every key.") {
		t.Fatalf("listed %v:\n%s", listed, page)
	}

	second := newPasskey(t)
	home.mu.Lock()
	home.waiting["pkw_2"] = waitingPasskey("pkw_2", second)
	home.mu.Unlock()
	b.do(http.MethodGet, "/passkey?ref=pkw_2", "", nil)
	entries := len(home.accounts.Log(rec.Identifier))
	home.accounts.Down = true
	page = body(b.post("/passkey/decide", url.Values{"ref": {"pkw_2"}, "key": {keyDigest(second)}, "decision": {"approve"}, "secret": {p}}))
	home.accounts.Down = false
	if !strings.Contains(page, "Your account could not be reached just now. Nothing was added; approve it again from Your devices.") ||
		len(home.accounts.Log(rec.Identifier)) != entries {
		t.Fatalf("an account that could not be read:\n%s", page)
	}
}

// The page's approval is bound to the whole key it drew, every field its
// add_key holds: drawn again under the same ref with any field changed,
// the earlier window's approval adds nothing, says the request changed and
// opens no key. A changed credential id or point is another valid key; a
// changed kid, alg or kind is no passkey at all, and the redraw drops the
// request.
func TestPasskey_AnApprovalIsBoundToEveryFieldOfTheKeyShown(t *testing.T) {
	changed := "That request changed since this window showed its code, so nothing was added. Approve it again from Your devices."
	for _, c := range []struct {
		field  string
		change func(k account.Key) map[string]any
	}{
		{"credential_id", func(k account.Key) map[string]any {
			k.CredentialID = []byte("another credential of the same key")
			return k.Map()
		}},
		{"pub", func(account.Key) map[string]any { return newPasskey(t).Map() }},
		{"kid", func(k account.Key) map[string]any {
			m := k.Map()
			m["kid"] = newPasskey(t).Kid
			return m
		}},
		{"alg", func(k account.Key) map[string]any {
			m := k.Map()
			m["alg"] = "ed25519"
			return m
		}},
		{"kind", func(k account.Key) map[string]any {
			m := k.Map()
			m["kind"] = "device"
			return m
		}},
	} {
		t.Run(c.field, func(t *testing.T) {
			home, b, p, rec, key := passkeyAsked(t)
			if page := body(b.do(http.MethodGet, "/passkey?ref=pkw_1", "", nil)); !strings.Contains(page, `name="key" value="`+keyDigest(key)+`"`) {
				t.Fatalf("not drawn:\n%s", page)
			}
			entries := len(home.accounts.Log(rec.Identifier))
			home.mu.Lock()
			record := waitingPasskey("pkw_1", key)
			record["key"] = c.change(key)
			home.waiting["pkw_1"] = record
			home.mu.Unlock()
			b.do(http.MethodGet, "/passkey?ref=pkw_1", "", nil)
			for _, secret := range []string{otherPassphrase(t, p), p} {
				page := body(b.post("/passkey/decide", url.Values{"ref": {"pkw_1"}, "key": {keyDigest(key)}, "decision": {"approve"}, "secret": {secret}}))
				if !strings.Contains(page, changed) || strings.Contains(page, "That is not this device's PIN or passphrase.") ||
					len(home.accounts.Log(rec.Identifier)) != entries {
					t.Fatalf("the earlier window's approval:\n%s", page)
				}
			}
		})
	}
}

// lostThenAnswered keeps the first append's effect and loses its answer,
// then answers the same bytes sent again with second, or, when second is
// nil, as the directory does.
type lostThenAnswered struct {
	base   http.RoundTripper
	second *http.Response
	sends  int
}

func (d *lostThenAnswered) RoundTrip(r *http.Request) (*http.Response, error) {
	if r.Method != http.MethodPost || !strings.HasSuffix(r.URL.Path, "/append") {
		return d.base.RoundTrip(r)
	}
	d.sends++
	if d.sends == 1 {
		resp, err := d.base.RoundTrip(r)
		if err == nil {
			resp.Body.Close()
		}
		return nil, errors.New("the answer was lost")
	}
	if d.second == nil {
		return d.base.RoundTrip(r)
	}
	resp := *d.second
	resp.Request = r
	return &resp, nil
}

func answered(status int, body string) *http.Response {
	return &http.Response{StatusCode: status, Header: http.Header{"Content-Type": {"application/json"}},
		Body: io.NopCloser(strings.NewReader(body))}
}

// A first send whose answer was lost is settled only by an answer to the
// same bytes sent again that shows the entry's state: the directory's
// exists, duplicate_key, or stale_head, after which the log is read again.
// A rate limit or a server error says nothing of the first send, so the
// page says it does not know. In each case the first send landed.
func TestPasskey_ALostSendIsSettledOnlyByAnAnswerThatShowsTheLog(t *testing.T) {
	unknown := "Your account's answer did not arrive, so this device does not know whether the passkey was added."
	for _, c := range []struct {
		name   string
		second *http.Response
		says   string
	}{
		{"rate limited", answered(http.StatusTooManyRequests, `{"error":"rate_limited","retry_after":60}`), unknown},
		{"server error", answered(http.StatusBadGateway, `{"error":"unavailable"}`), unknown},
		{"exists", nil, "Added to your account. The browser that asked signs in with its passkey now."},
		{"duplicate key", answered(http.StatusConflict, `{"error":"duplicate_key"}`), "Your account lists that passkey already."},
		{"stale head", answered(http.StatusConflict, `{"error":"stale_head"}`), "Your account lists that passkey already."},
	} {
		t.Run(c.name, func(t *testing.T) {
			home, b, p, rec, key := passkeyAsked(t)
			b.do(http.MethodGet, "/passkey?ref=pkw_1", "", nil)
			base := http.DefaultTransport
			if b.shell.cfg.Client != nil && b.shell.cfg.Client.Transport != nil {
				base = b.shell.cfg.Client.Transport
			}
			transport := &lostThenAnswered{base: base, second: c.second}
			b.shell.cfg.Client = &http.Client{Transport: transport}
			page := body(b.post("/passkey/decide", url.Values{"ref": {"pkw_1"}, "key": {keyDigest(key)}, "decision": {"approve"}, "secret": {p}}))
			_, listed := home.accounts.State(t, rec.Identifier).Key(key.Kid)
			if transport.sends != 2 || !listed || !strings.Contains(page, c.says) || strings.Contains(page, "not added") ||
				strings.Contains(page, "Nothing was added") {
				t.Fatalf("sent %d, listed %v:\n%s", transport.sends, listed, page)
			}
		})
	}
}

// A CYFR that requires a company sign-in closes the channel 1013 with the
// class forbidden, one whose bound is spent with when to try again; any
// other try-again close is a CYFR not reachable now. The page says which,
// in the app's own words for the first two.
func TestChannel_ACompanySignInIsToldApartFromAnUnreachableCYFR(t *testing.T) {
	for _, tc := range []struct{ reason, want string }{
		{"forbidden", CompanySignIn},
		{"unavailable", "CYFR could not be reached"},
		{"rate_limited; retry_after_s=37", "CYFR is refusing attempts for the moment. Try again in 37 seconds."},
		{"rate_limited; retry_after_s=1", "CYFR is refusing attempts for the moment. Try again in 1 second."},
		{"rate_limited", "CYFR could not be reached"},
	} {
		t.Run(tc.reason, func(t *testing.T) {
			home := newFakeHome(t)
			b := newBox(t, home, t.TempDir())
			setUpAndOpen(t, home, b)
			home.mu.Lock()
			conns := home.conns
			home.conns = nil
			home.mu.Unlock()
			for _, c := range conns {
				c.Close(websocket.StatusTryAgainLater, tc.reason)
			}
			deadline := time.Now().Add(5 * time.Second)
			for b.shell.Unlocked() && time.Now().Before(deadline) {
				time.Sleep(10 * time.Millisecond) // sleep-ok: polls the lock the close starts, bounded by deadline
			}
			if page := b.page(); b.shell.Unlocked() || !strings.Contains(html.UnescapeString(page), tc.want) {
				t.Fatalf("the box did not lock saying %q: %s", tc.want, page)
			}
		})
	}
}

// Adding the device to an account reads that account's log at the
// account service the registry names. One other than this CYFR's, the one
// approved for it, is never contacted: the page says where the account is.
func TestEnroll_AnAccountServiceOtherThanThisCYFRsIsNeverContacted(t *testing.T) {
	var contacted atomic.Int32
	other := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		contacted.Add(1)
		http.NotFound(w, r)
	}))
	defer other.Close()
	var registry *httptest.Server
	registry = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/account/config.json":
			_ = json.NewEncoder(w).Encode(map[string]any{"directory": registry.URL, "registry": registry.URL, "policy": nil})
		case "/v1/handles/alice":
			_ = json.NewEncoder(w).Encode(map[string]any{"protocol": "cyfr-handle/v1", "registry": "127.0.0.1", "handle": "alice",
				"identifier": "per_" + strings.Repeat("ab", 32), "directory": other.URL})
		default:
			http.NotFound(w, r)
		}
	}))
	defer registry.Close()
	b := newBoxAt(t, newFakeHome(t), t.TempDir(), registry.URL)
	p := b.shown()
	b.post("/make", url.Values{"secret": {p}, "again": {p}})
	b.post("/enroll", url.Values{"name": {"alice"}})
	page := html.UnescapeString(b.page())
	if !strings.Contains(page, "@alice's account is at the account service "+other.URL+", not at "+registry.URL) {
		t.Fatalf("the page did not say where the account is:\n%s", page)
	}
	if n := contacted.Load(); n != 0 {
		t.Fatalf("the account service the registry named was contacted %d times", n)
	}
}

// A remote CYFR selected over a local project's working record that
// refuses the device's first hello (4403) changes nothing in the list:
// only an admission that succeeded adds the CYFR's entry.
func TestSelection_ARefusedFirstHelloLeavesTheWorkingRecord(t *testing.T) {
	home := newFakeHome(t)
	// Someone is set up there already, and the door admits no one new.
	home.mu.Lock()
	home.setupUsed = true
	home.mu.Unlock()
	file := Homes(filepath.Join(t.TempDir(), "homes.json"))
	box, err := file.SelectLocal("http://localhost:4000", "/home/ada/cyfr", Typed)
	if err == nil {
		err = box.Commit("")
	}
	if err != nil {
		t.Fatal(err)
	}
	admit(t, box, "pcl_box", `{"box":1}`)
	before, _ := os.ReadFile(string(file))
	sel, err := file.Select(home.address(), home.accounts.URL(), true, Typed)
	if err != nil {
		t.Fatal(err)
	}
	b := newBoxAt(t, home, t.TempDir(), home.accounts.URL(), func(c *Config) { c.Clients = sel })
	b.setUp("alice")
	b.post("/saved", nil)
	if b.shell.Unlocked() || len(home.hellosSeen()) != 1 {
		t.Fatalf("the CYFR did not refuse the first hello: hellos %v", home.hellosSeen())
	}
	if after, _ := os.ReadFile(string(file)); string(after) != string(before) {
		t.Fatalf("a refused first hello replaced the working record:\n%s", after)
	}
}

// A device that locks itself unlocks only while what would lock it is
// known to work: otherwise no PIN or passphrase opens it and no open
// device hands out a ticket, and the page says why in place of the form.
func TestUnwatched_PermitsNoUnlock(t *testing.T) {
	const why = "This screen stays locked because it cannot tell when this device goes to sleep."
	home := newFakeHome(t)
	var unwatched atomic.Value
	unwatched.Store("")
	b := newBoxAt(t, home, t.TempDir(), home.accounts.URL(), func(c *Config) {
		c.Unwatched = func() string { return unwatched.Load().(string) }
	})
	p := b.setUp("alice")
	b.post("/saved", nil)
	if !b.shell.Unlocked() {
		t.Fatalf("a watched box did not finish its setup:\n%s", b.page())
	}

	unwatched.Store(why)
	if w := b.post("/open", nil); strings.Contains(w.Header().Get("Location")+w.Body.String(), "/auth/device/complete") {
		t.Fatal("an unwatched box handed out a ticket")
	}
	b.shell.Lock("")
	if w := b.post("/unlock", url.Values{"secret": {p}}); b.shell.Unlocked() || strings.Contains(w.Header().Get("Location")+w.Body.String(), "/auth/device/complete") {
		t.Fatal("an unwatched box unlocked")
	}
	page := b.page()
	if !strings.Contains(page, why) || strings.Contains(page, `action="/unlock"`) || strings.Contains(page, "CYFR is locked") {
		t.Fatalf("an unwatched box's page is\n%s", page)
	}

	unwatched.Store("")
	ticketOf(t, b.post("/unlock", url.Values{"secret": {p}}), home)
}
