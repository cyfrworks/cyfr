// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package shell

import (
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
	"github.com/cyfr/codex/internal/disk"
	"github.com/cyfr/codex/internal/holder"
)

// box is one screen under test: its shell, its pages and the home it
// talks to.
type box struct {
	t        *testing.T
	home     *fakeHome
	shell    *Shell
	srv      *Server
	record   string
	restarts atomic.Int32
	now      atomic.Int64
}

func newBox(t *testing.T, home *fakeHome, dir string) *box {
	t.Helper()
	b := &box{t: t, home: home, record: filepath.Join(dir, "holder.json")}
	b.now.Store(time.Now().UnixNano())
	sh, err := New(Config{
		Address: home.address(), Client: home.srv.Client(), Record: b.record, DataDir: dir,
		Tokens:  func() (string, string) { return home.setupToken, home.restoreToken },
		Restart: func() { b.restarts.Add(1) },
		Detect:  func(string) disk.Report { return disk.Report{Root: disk.Encrypted, Data: disk.Unencrypted} },
		Now:     func() time.Time { return time.Unix(0, b.now.Load()) },
		Chip:    func() bool { return false },
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

// passphrase is the one the setup page shows.
func (b *box) passphrase() string {
	b.t.Helper()
	m := codeShape.FindStringSubmatch(b.page())
	if m == nil {
		b.t.Fatal("the setup page shows no passphrase")
	}
	return m[1]
}

// setUp sets the box up as name, through the pages, to the recovery page.
func (b *box) setUp(name string) string {
	b.t.Helper()
	p := b.passphrase()
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

// A box without a chip refuses six digits and sets up with the generated
// passphrase given twice: its key is written before CYFR is asked, the
// recovery code is shown and, once said saved, Chrome goes into Prism
// with a one-time ticket in the fragment. CYFR never hears the
// passphrase.
func TestSetup_SetsUpWithThePassphraseAndOpensPrism(t *testing.T) {
	home := newFakeHome(t)
	b := newBox(t, home, t.TempDir())
	home.recordPath = b.record

	if !strings.Contains(b.page(), "This box keeps its data unencrypted, whoever takes it reads everything: its CYFR data volume is not encrypted.") {
		t.Fatal("setup does not warn about the unencrypted data volume")
	}
	b.post("/setup", url.Values{"name": {"alice"}, "secret": {"123456"}, "again": {"123456"}})
	if page := b.page(); !strings.Contains(page, "needs the six-word passphrase") {
		t.Fatalf("six digits were not refused:\n%s", page)
	}
	if _, err := os.Stat(b.record); !os.IsNotExist(err) || home.heard("123456") || len(home.opsSeen()) != 0 {
		t.Fatal("a refused PIN made a key or reached CYFR")
	}

	p := b.setUp("alice")
	info, err := os.Stat(b.record)
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("the key record: %v %v", info, err)
	}
	if !slices.Equal(home.recordAtChallenge, []bool{true}) || home.completes != 1 {
		t.Fatalf("the key was not written before CYFR was asked (%v), or completes %d", home.recordAtChallenge, home.completes)
	}
	page := b.page()
	if !strings.Contains(page, "CYFR-TEST-RECOVERY-CODE") || !strings.Contains(page, "<svg") || !strings.Contains(page, `id="print"`) {
		t.Fatalf("the recovery page shows no code, QR or Print:\n%s", page)
	}
	w := b.post("/saved", nil)
	ticket := ticketOf(t, w, home)
	if ticket != "TICKET-ses_1" {
		t.Fatalf("ticket %q", ticket)
	}
	if strings.Contains(b.page(), "CYFR-TEST-RECOVERY-CODE") {
		t.Fatal("the recovery code is still shown after I saved it")
	}
	if got := home.opsSeen(); !slices.Equal(got, []string{"registry.register", "person.recovery_code_saved", "session.unlock", "session.unlock"}) {
		t.Fatalf("operations %v", got)
	}
	if home.heard(p) || home.heard(strings.ReplaceAll(p, " ", "+")) {
		t.Fatal("CYFR heard the passphrase")
	}
	rec, _ := holder.Load(b.record)
	if rec.RequestID != "" || rec.ClientID == "" || len(rec.Certificate) == 0 {
		t.Fatalf("the record after setup: %+v", rec)
	}
	if caps := home.capabilities; len(caps) == 0 || !slices.Equal(caps[0], []string{"root_encrypted", "data_unencrypted"}) {
		t.Fatalf("capabilities %v", caps)
	}
}

// A complete whose answer is lost is recovered by resume with the same key
// and request: CYFR enrolls one key, once.
func TestSetup_ALostAnswerIsResumedWithTheSameKey(t *testing.T) {
	home := newFakeHome(t)
	home.dropComplete = true
	b := newBox(t, home, t.TempDir())
	b.setUp("alice")
	if home.completes != 1 || home.resumes != 1 || len(home.enrolled) != 1 {
		t.Fatalf("completes %d resumes %d enrolled %d", home.completes, home.resumes, len(home.enrolled))
	}
	if !strings.Contains(b.page(), "CYFR-TEST-RECOVERY-CODE") {
		t.Fatal("the resumed setup shows no recovery code")
	}
}

// A setup interrupted before CYFR answered keeps its key: the next run of
// the shell, from the record alone, finishes it with the same key and
// request, never a new one.
func TestFinish_ARestartedShellFinishesWithTheSameKey(t *testing.T) {
	home := newFakeHome(t)
	home.downComplete = true
	dir := t.TempDir()
	b := newBox(t, home, dir)
	p := b.setUp("alice")
	if !strings.Contains(b.page(), "Setting up did not finish") {
		t.Fatal("the interrupted setup says nothing")
	}
	first, _ := holder.Load(b.record)
	if first == nil || len(first.Certificate) != 0 {
		t.Fatal("no key record kept, or a certificate from nowhere")
	}

	again := newBox(t, home, dir)
	if !strings.Contains(again.page(), "Finish setting up") {
		t.Fatal("the restarted shell does not offer to finish")
	}
	again.post("/finish", url.Values{"name": {"alice"}, "secret": {p}})
	rec, _ := holder.Load(again.record)
	e := home.enrolled[first.RequestID]
	if e == nil || len(home.enrolled) != 1 || string(e.key) != string(first.PublicKey) || len(rec.Certificate) == 0 {
		t.Fatalf("finished with another key or request: %+v", home.enrolled)
	}
}

// A name cyfr.run holds for someone else asks for another, and cyfr.run
// not answering asks to try again; neither enrolls anyone again.
func TestSetup_ANameConflictOrOutageNeverEnrollsAgain(t *testing.T) {
	home := newFakeHome(t)
	home.taken["alice"] = true
	home.registryDown = 1
	b := newBox(t, home, t.TempDir())
	b.setUp("alice")
	if page := b.page(); !strings.Contains(page, "cyfr.run did not answer") || !strings.Contains(page, `action="/name"`) {
		t.Fatalf("the outage asks nothing:\n%s", page)
	}
	b.post("/name", url.Values{"name": {"alice"}})
	if page := b.page(); !strings.Contains(page, "Someone holds the name alice") {
		t.Fatalf("the conflict asks nothing:\n%s", page)
	}
	if w := b.post("/saved", nil); w.Header().Get("Location") != "/" {
		t.Fatal("I saved it passed a name not yet taken")
	}
	b.post("/name", url.Values{"name": {"alice2"}})
	if !strings.Contains(b.page(), "CYFR-TEST-RECOVERY-CODE") {
		t.Fatal("the recovery code does not follow the name")
	}
	if home.completes != 1 || len(home.enrolled) != 1 {
		t.Fatalf("enrolled again: completes %d", home.completes)
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

// A channel the home ends locks the box, saying why.
func TestChannel_AnEndedStandingLocksTheBox(t *testing.T) {
	home := newFakeHome(t)
	b := newBox(t, home, t.TempDir())
	p := setUpAndOpen(t, home, b)
	home.closeChannels(4403)
	deadline := time.Now().Add(5 * time.Second)
	for b.shell.Unlocked() && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if b.shell.Unlocked() || b.restarts.Load() != 1 || !strings.Contains(b.page(), "removed from CYFR") {
		t.Fatal("a revoked pairing did not lock the box")
	}
	home.mu.Lock()
	home.closeWith = 4403
	home.mu.Unlock()
	b.post("/unlock", url.Values{"secret": {p}})
	if !strings.Contains(b.page(), "removed from CYFR") || b.shell.Unlocked() {
		t.Fatal("a revoked box unlocked")
	}
	_ = websocket.StatusNormalClosure
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

// A replacement box restores under the restore token and the recovery
// code, and enrolls a key of its own: never the old box's.
func TestRestore_EnrollsANewKeyUnderTheRestoreSession(t *testing.T) {
	home := newFakeHome(t)
	old := newBox(t, home, t.TempDir())
	setUpAndOpen(t, home, old)
	oldRec, _ := holder.Load(old.record)

	home.restoreToken = strings.Repeat("ab", 32)
	b := newBox(t, home, t.TempDir())
	p := b.passphrase()
	if !strings.Contains(b.page(), "Restore onto this box") {
		t.Fatal("no restore page")
	}
	b.post("/restore", url.Values{"code": {"CYFR-WRONG"}, "secret": {p}, "again": {p}})
	if _, err := os.Stat(b.record); !os.IsNotExist(err) || !strings.Contains(b.page(), "restores no one here") {
		t.Fatal("a wrong code made a key, or was not said")
	}
	w := b.post("/restore", url.Values{"code": {"CYFR-RIGHT-CODE"}, "secret": {p}, "again": {p}})
	ticketOf(t, w, home)
	rec, _ := holder.Load(b.record)
	if rec.Admission != "restore" || string(rec.PublicKey) == string(oldRec.PublicKey) || len(home.enrolled) != 2 {
		t.Fatalf("restore enrolled %+v", rec)
	}
	if home.heard(p) || home.heard(strings.ReplaceAll(p, " ", "+")) {
		t.Fatal("CYFR heard the passphrase")
	}
}
