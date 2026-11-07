// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package shell

import (
	"bytes"
	"crypto/ed25519"
	"html"
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
	now      atomic.Int64
}

func newBox(t *testing.T, home *fakeHome, dir string) *box {
	t.Helper()
	b := &box{t: t, home: home, dir: dir, record: filepath.Join(dir, "holder.json")}
	b.now.Store(time.Now().UnixNano())
	sh, err := New(Config{
		Address: home.address(), Client: home.srv.Client(), Record: b.record, DataDir: dir,
		Directory:     home.accounts.URL(),
		Tokens:        func() string { return home.setupToken },
		SetupFromPage: true,
		Restart:       func() { b.restarts.Add(1) },
		Detect:        func(string) disk.Report { return disk.Report{Root: disk.Encrypted, Data: disk.Unencrypted} },
		Now:           func() time.Time { return time.Unix(0, b.now.Load()) },
		Chip:          func() bool { return false },
	})
	if err != nil {
		t.Fatal(err)
	}
	b.shell, b.srv = sh, &Server{Shell: sh}
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

func (b *box) post(path string, fields url.Values) *httptest.ResponseRecorder {
	return b.do(http.MethodPost, path, Origin, fields)
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

// shown is the first code-styled text the page shows: the passphrase on
// the setup page, the recovery code on its own.
func (b *box) shown() string {
	b.t.Helper()
	m := codeShape.FindStringSubmatch(b.page())
	if m == nil {
		b.t.Fatalf("the page shows no code:\n%s", b.page())
	}
	return m[1]
}

// setUp sets the box up as name, through the pages, to the recovery page,
// and answers its passphrase.
func (b *box) setUp(name string) string {
	b.t.Helper()
	p := b.shown()
	w := b.post("/setup", url.Values{"name": {name}, "secret": {p}, "again": {p}})
	if w.Code != http.StatusSeeOther || w.Header().Get("Location") != "/" {
		b.t.Fatalf("setup answered %d %q", w.Code, w.Header().Get("Location"))
	}
	return p
}

func ticketOf(t *testing.T, w *httptest.ResponseRecorder, home *fakeHome) string {
	t.Helper()
	loc := w.Header().Get("Location")
	prefix := home.address() + "/auth/device/complete#"
	if w.Code != http.StatusSeeOther || !strings.HasPrefix(loc, prefix) {
		t.Fatalf("answered %d %q, want a redirect to %s<ticket>", w.Code, loc, prefix)
	}
	return strings.TrimPrefix(loc, prefix)
}

func (b *box) client() ClientRecord {
	c, err := ClientFile(filepath.Join(b.dir, "client.json")).Load()
	if err != nil {
		b.t.Fatal(err)
	}
	return c
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

	if !strings.Contains(b.page(), "This box keeps its data unencrypted, whoever takes it reads everything: its CYFR data volume is not encrypted.") {
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
	page := b.page()
	code := b.shown()
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
	code := b.shown()
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
	if loc := w.Header().Get("Location"); loc != "/" {
		t.Fatalf("resume answered %q", loc)
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

// Where the account service names terms, setting up without accepting
// them makes nothing and shows them; accepted, the acceptance precedes the
// name's claim, and newer terms the registry asks for meanwhile are asked
// again before it.
func TestSetup_TheTermsAreAcceptedFirst(t *testing.T) {
	home := newFakeHome(t)
	home.accounts.Policy = &account.Policy{Version: "2026-10", URL: "https://cyfr.example/terms"}
	b := newBox(t, home, t.TempDir())
	if page := b.page(); !strings.Contains(page, "I accept the terms at https://cyfr.example/terms") {
		t.Fatalf("the setup page shows no terms:\n%s", page)
	}
	p := b.shown()
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
	if !strings.Contains(page, kid[7:23]) || !strings.Contains(page, addURL) || !strings.Contains(page, "cyfr device approve "+b64(rec.PublicKey)) || !strings.Contains(page, "<svg") {
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
	if !strings.Contains(page, "Your account no longer lists this screen's key.") || !strings.Contains(page, code) ||
		!strings.Contains(page, "cyfr device approve "+b64(rec.PublicKey)) || !strings.Contains(page, "<svg") {
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

// setUpAndOpen sets a box up through to Prism and answers its passphrase.
func setUpAndOpen(t *testing.T, home *fakeHome, b *box) string {
	t.Helper()
	p := b.setUp("alice")
	ticketOf(t, b.post("/saved", nil), home)
	return p
}

// A lock submits the pre-signed lock of each session the unlock reserved,
// redeemed or not, closes the channel, erases the key and starts Chrome
// again on the lock page; a wrong passphrase after it is said and nothing
// reaches CYFR; the right one unlocks a new session.
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
	b.post("/lock", nil)
	if len(home.locked) != 2 || b.restarts.Load() != 1 {
		t.Fatal("a second lock did more")
	}

	ops := len(home.opsSeen())
	b.post("/unlock", url.Values{"secret": {otherPassphrase(t, p)}})
	if page := b.page(); !strings.Contains(page, "not this screen") || len(home.opsSeen()) != ops {
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
	if b.shell.Unlocked() || b.restarts.Load() != 1 || !strings.Contains(b.page(), "it was removed, or CYFR does not admit your account") {
		t.Fatal("an ended standing did not lock the box")
	}
	if c := b.client(); c.ClientID != "pcl_1" || len(c.Certificate) != 0 {
		t.Fatalf("the client kept %+v", c)
	}
	home.mu.Lock()
	home.members = map[string]bool{}
	home.mu.Unlock()
	b.post("/unlock", url.Values{"secret": {p}})
	if !strings.Contains(b.page(), "it was removed, or CYFR does not admit your account") || b.shell.Unlocked() {
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

// A connection the network silently drops, the home still standing, locks
// the box at the next report: the shell's ping goes unanswered within its
// bound, the channel ends as unreachable, and the lock page says so, not
// that the screen idled.
func TestChannel_ASilentlyDroppedConnectionLocksTheBox(t *testing.T) {
	oldEvery, oldWithin := reportEvery.Get(), heardWithin.Get()
	reportEvery.Set(200 * time.Millisecond)
	heardWithin.Set(300 * time.Millisecond)
	t.Cleanup(func() { reportEvery.Set(oldEvery); heardWithin.Set(oldWithin) })
	home := newFakeHome(t)
	b := newBox(t, home, t.TempDir())
	setUpAndOpen(t, home, b)
	home.stall(t)
	deadline := time.Now().Add(5 * time.Second)
	for b.shell.Unlocked() && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	page := b.page()
	if b.shell.Unlocked() || !strings.Contains(page, "could not be reached") || strings.Contains(page, "five minutes") {
		t.Fatalf("a dropped connection did not lock the box as unreachable (unlocked=%v):\n%s", b.shell.Unlocked(), page)
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
	if len(home.confirmed) != 0 || !strings.Contains(body(w), "not this screen") {
		t.Fatal("a wrong passphrase confirmed, or was not said")
	}
	w = b.post("/confirm/decide", url.Values{"ref": {"cnr_1"}, "decision": {"confirm"}, "secret": {p}})
	if len(home.confirmed) != 1 || home.confirmed[0]["ref"] != "cnr_1" || !strings.Contains(body(w), "Confirmed on this screen") {
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
	if len(home.opsSeen()) != ops || !strings.Contains(body(w), "Unlock this screen first") {
		t.Fatal("a locked box fetched a confirmation")
	}
}
