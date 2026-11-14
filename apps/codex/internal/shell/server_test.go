// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package shell

import (
	"encoding/base64"
	"fmt"
	"html"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"regexp"
	"strings"
	"testing"

	"github.com/cyfr/codex/internal/account"
	"github.com/cyfr/codex/internal/holder"
)

// The listener is literal loopback: an address, never a name.
func TestListen_IsLiteralLoopback(t *testing.T) {
	host, _, err := net.SplitHostPort(Listen)
	if ip := net.ParseIP(host); err != nil || ip == nil || !ip.IsLoopback() || ip.To4() == nil {
		t.Fatalf("Listen %q", Listen)
	}
}

// Every request names the listener exactly; every POST comes from the
// shell's own pages, or for Lock and Confirm alone from Prism; GETs only
// open the page; nothing answers a preflight or grants CORS; and every
// answer carries the pages' headers.
func TestServer_AdmitsOnlyTheShellsOwnRequests(t *testing.T) {
	home := newFakeHome(t)
	b := newBox(t, home, t.TempDir())
	prism := home.address()
	cases := []struct {
		name, method, host, path, origin string
		want                             int
	}{
		{"the page", "GET", Listen, "/", "", 200},
		{"another host name", "GET", "localhost:7340", "/", "", 421},
		{"a rebinding name", "GET", "evil.example:7340", "/", "", 421},
		{"no Origin", "POST", Listen, "/unlock", "", 403},
		{"an opaque Origin", "POST", Listen, "/unlock", "null", 403},
		{"an opaque Origin for Lock", "POST", Listen, "/lock", "null", 403},
		{"another Origin", "POST", Listen, "/unlock", "https://evil.example", 403},
		{"Prism's Origin for an unlock", "POST", Listen, "/unlock", prism, 403},
		{"Prism's Origin for a setup", "POST", Listen, "/setup", prism, 403},
		{"Prism's Origin for a decision", "POST", Listen, "/confirm/decide", prism, 403},
		{"Prism's Origin for Lock", "POST", Listen, "/lock", prism, 303},
		{"Confirm on this device, a navigation", "GET", Listen, "/confirm?ref=cnr_x", "", 200},
		{"Confirm by POST", "POST", Listen, "/confirm", prism, 404},
		{"Prism's Lock, a navigation", "GET", Listen, "/lock", "", 303},
		{"a preflight", "OPTIONS", Listen, "/lock", prism, 404},
		{"an unknown path", "POST", Listen, "/sign", Origin, 404},
	}
	for _, c := range cases {
		req := httptest.NewRequest(c.method, "http://"+c.host+c.path, strings.NewReader(url.Values{"x": {"y"}}.Encode()))
		req.Host = c.host
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		if c.origin != "" {
			req.Header.Set("Origin", c.origin)
		}
		w := httptest.NewRecorder()
		b.srv.ServeHTTP(w, req)
		if w.Code != c.want {
			t.Errorf("%s: %d, want %d", c.name, w.Code, c.want)
		}
		h := w.Header()
		csp := h.Get("Content-Security-Policy")
		if h.Get("Cache-Control") != "no-store" || h.Get("Referrer-Policy") != "same-origin" || h.Get("X-Frame-Options") != "DENY" ||
			!strings.Contains(csp, "frame-ancestors 'none'") || !strings.Contains(csp, "default-src 'none'") ||
			!strings.Contains(csp, "form-action 'self' "+prism+";") || strings.Contains(csp, "unsafe") {
			t.Errorf("%s: headers %v", c.name, h)
		}
		for k := range h {
			if strings.HasPrefix(k, "Access-Control-") {
				t.Errorf("%s: answers %s", c.name, k)
			}
		}
	}
}

// A POST whose body is not a form, or names a field twice, is refused
// before it reaches the shell.
func TestServer_RefusesWhatIsNotAForm(t *testing.T) {
	home := newFakeHome(t)
	b := newBox(t, home, t.TempDir())
	for name, req := range map[string]*http.Request{
		"JSON":      httptest.NewRequest("POST", "http://"+Listen+"/unlock", strings.NewReader(`{"secret":"1"}`)),
		"twice":     httptest.NewRequest("POST", "http://"+Listen+"/unlock", strings.NewReader("secret=1&secret=2")),
		"bad quote": httptest.NewRequest("POST", "http://"+Listen+"/unlock", strings.NewReader("secret=%zz")),
	} {
		req.Header.Set("Origin", Origin)
		if name != "JSON" {
			req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		} else {
			req.Header.Set("Content-Type", "application/json")
		}
		w := httptest.NewRecorder()
		b.srv.ServeHTTP(w, req)
		if w.Code < 400 {
			t.Errorf("%s: %d", name, w.Code)
		}
	}
}

// The pages run only the three scripts their policy hashes: every page
// the one that keeps the proof, the recovery page shown its code the one
// that prints it too, and the policy admits those three and no other.
func TestPages_RunOnlyTheHashedScripts(t *testing.T) {
	home := newFakeHome(t)
	b := newBox(t, home, t.TempDir())
	b.setUp("alice")
	for name, c := range map[string]struct {
		page    *httptest.ResponseRecorder
		scripts []string
	}{
		"the plain read":     {b.do(http.MethodGet, "/", "", nil), []string{keepScript}},
		"the code's request": {b.post("/recovery", nil), []string{printScript, keepScript}},
	} {
		page := c.page.Body.String()
		want := ""
		for _, script := range c.scripts {
			want += "<script>" + script + "</script>"
		}
		got := strings.Join(regexp.MustCompile(`<script>[^<]*</script>`).FindAllString(page, -1), "")
		if got != want || strings.Count(page, "<script") != len(c.scripts) {
			t.Errorf("%s runs %s", name, got)
		}
		if !strings.Contains(page, "<style>"+style+"</style>") {
			t.Errorf("%s: the style is not the hashed one", name)
		}
		csp := c.page.Header().Get("Content-Security-Policy")
		if !strings.Contains(csp, "script-src "+hash(printScript)+" "+hash(closeScript)+" "+hash(keepScript)+";") {
			t.Errorf("%s: the policy %s", name, csp)
		}
	}
}

// The shell's origin and Prism's two entries into it are the fixture's
// exchange.shell: Lock a POST with no form, Confirm a navigation naming
// its ref.
func TestServer_EntriesAreTheFixtures(t *testing.T) {
	var v struct {
		Exchange struct {
			Shell struct {
				Origin string `json:"origin"`
				Lock   struct {
					Method, Path string
					Form         []string
				} `json:"lock"`
				Confirm struct {
					Method, Path, Target string
					Query                []string
				} `json:"confirm"`
			} `json:"shell"`
		} `json:"exchange"`
	}
	fixture(t, "device_unlock.json", &v)
	sh := v.Exchange.Shell
	if sh.Origin != Origin || (sh.Lock.Method != "POST" && sh.Lock.Method != "GET") || sh.Lock.Path != "/lock" || len(sh.Lock.Form) != 0 ||
		sh.Confirm.Method != "GET" || sh.Confirm.Path != "/confirm" || len(sh.Confirm.Query) != 1 || sh.Confirm.Query[0] != "ref" {
		t.Fatalf("the fixture's shell %+v, the shell's origin %s", sh, Origin)
	}
	if _, ok := actions[sh.Lock.Path]; !ok || !actions[sh.Lock.Path].prism {
		t.Fatal("Prism cannot post the fixture's Lock")
	}
}

// Reading a page changes nothing: an action's notice stays on every read
// until the next action.
func TestServer_ReadingAPageChangesNothing(t *testing.T) {
	home := newFakeHome(t)
	b := newBox(t, home, t.TempDir())
	b.post("/setup", url.Values{"name": {"alice"}, "secret": {"123456"}, "again": {"123456"}})
	first, second := b.page(), b.page()
	if !strings.Contains(first, "needs the six-word passphrase") || first != second {
		t.Fatal("a read changed the page")
	}
}

// Prism's Lock is a top-level navigation to /lock: a GET from no page of
// the shell's locks the screen, retires each session it opened and
// returns to the lock page, and a repeated one is a harmless success.
func TestServer_PrismsLockIsANavigationThatLocks(t *testing.T) {
	home := newFakeHome(t)
	b := newBox(t, home, t.TempDir())
	setUpAndOpen(t, home, b)
	w := b.do(http.MethodGet, "/lock", "", nil)
	if w.Code != http.StatusSeeOther || w.Header().Get("Location") != "/" || b.shell.Unlocked() || len(home.locked) != 1 {
		t.Fatalf("GET /lock answered %d %q, unlocked %v, locked %v", w.Code, w.Header().Get("Location"), b.shell.Unlocked(), home.locked)
	}
	if w := b.do(http.MethodGet, "/lock", "", nil); w.Code != http.StatusSeeOther || len(home.locked) != 1 || b.restarts.Load() != 1 {
		t.Fatalf("a repeated GET /lock did more: %d %v", w.Code, home.locked)
	}
}

// onwardRoutes are the nine POSTs that end in onward, each of which hands
// the browser a ticket once the box is unlocked.
var onwardRoutes = []string{"/setup", "/make", "/create", "/enroll", "/saved", "/resume", "/unlock", "/name", "/open"}

var proofShape = regexp.MustCompile(`data-proof="([^"]*)"`)

// proofIn is the proof an answer hands its page, or "" for none.
func proofIn(w *httptest.ResponseRecorder) string {
	if m := proofShape.FindStringSubmatch(w.Body.String()); m != nil {
		return m[1]
	}
	return ""
}

// toHome is whether an answer sends the browser to the home with a ticket,
// by a redirect or by its page.
func toHome(w *httptest.ResponseRecorder, home *fakeHome) bool {
	prefix := home.address() + "/auth/device/complete#"
	return strings.HasPrefix(w.Header().Get("Location"), prefix) || strings.Contains(w.Body.String(), prefix)
}

// SEC-1: a local program that names the shell's Host and Origin but holds
// no proof gets no ticket from any of the nine routes of an unlocked box:
// each answers exactly a redirect to the page, with no body, and no
// session is reserved at the home.
func TestServer_NoRouteHandsATicketWithoutTheProof(t *testing.T) {
	home := newFakeHome(t)
	b := newBox(t, home, t.TempDir())
	setUpAndOpen(t, home, b)
	for _, route := range onwardRoutes {
		ops := len(home.opsSeen())
		w := b.do(http.MethodPost, route, Origin, url.Values{"x": {"y"}})
		if w.Code != http.StatusSeeOther || w.Header().Get("Location") != "/" || w.Body.Len() != 0 || len(home.opsSeen()) != ops {
			t.Errorf("%s answered %d %q %q, the home saw %v", route, w.Code, w.Header().Get("Location"), w.Body.String(), home.opsSeen()[ops:])
		}
	}
	if !b.shell.Unlocked() {
		t.Fatal("the box locked meanwhile, so the routes were not asked while unlocked")
	}
}

// #1549: after setup, a plain local read of the page shows the recovery
// page without its code or the code's QR.
func TestServer_APlainReadShowsNoRecoveryCode(t *testing.T) {
	home := newFakeHome(t)
	b := newBox(t, home, t.TempDir())
	p := b.shown()
	b.post("/setup", url.Values{"name": {"alice"}, "secret": {p}, "again": {p}})
	v := b.shell.View()
	if v.Page != PageRecovery || !strings.HasPrefix(v.RecoveryCode, "CYFR-") {
		t.Fatalf("the box is not showing a recovery code: %+v", v)
	}
	page := b.do(http.MethodGet, "/", "", nil).Body.String()
	if !strings.Contains(page, "<h1>Your recovery code</h1>") || strings.Contains(page, v.RecoveryCode) ||
		strings.Contains(page, html.EscapeString(v.RecoveryCode)) || strings.Contains(page, "<svg") {
		t.Fatalf("a plain read of the recovery page shows the code %v, its QR %v", strings.Contains(page, v.RecoveryCode), strings.Contains(page, "<svg"))
	}
}

// The recovery page read plainly asks for its code by a POST with the
// proof the page keeps; that POST without the current proof is shown the
// page without the code and without the form, so a page holding a stale
// proof does not ask again and again.
func TestServer_TheRecoveryCodeGoesOnlyToTheProof(t *testing.T) {
	home := newFakeHome(t)
	b := newBox(t, home, t.TempDir())
	b.setUp("alice")
	code := b.shell.View().RecoveryCode
	plain := b.do(http.MethodGet, "/", "", nil).Body.String()
	if !strings.Contains(plain, `<form id="reveal" method="post" action="/recovery"><input type="hidden" name="proof"></form>`) {
		t.Fatal("the plain read does not ask for the code")
	}
	for name, proof := range map[string]string{"no proof": "", "another proof": "AAAA" + b.proof[4:], "a proof cut short": b.proof[:20]} {
		page := b.do(http.MethodPost, "/recovery", Origin, url.Values{"proof": {proof}}).Body.String()
		if strings.Contains(page, code) || strings.Contains(page, "<svg") || strings.Contains(page, `id="reveal"`) || !strings.Contains(page, "<h1>Your recovery code</h1>") {
			t.Errorf("%s: shown the code %v, its QR %v, the form %v", name, strings.Contains(page, code), strings.Contains(page, "<svg"), strings.Contains(page, `id="reveal"`))
		}
	}
	if got := b.recovery(); got != code {
		t.Fatalf("the page holding the proof is shown %q, the box holds %q", got, code)
	}
}

// The proof is 32 bytes, handed over by the answer whose PIN opened the key
// and by no other answer; a wrong PIN, or an unlock of an unlocked box,
// opens nothing and hands over none.
func TestServer_TheProofIsHandedOverOnlyByTheOpening(t *testing.T) {
	home := newFakeHome(t)
	b := newBox(t, home, t.TempDir())
	p := setUpAndOpen(t, home, b)
	b.do(http.MethodGet, "/lock", "", nil)
	wrong := b.do(http.MethodPost, "/unlock", Origin, url.Values{"secret": {otherPassphrase(t, p)}})
	if wrong.Code != http.StatusSeeOther || wrong.Header().Get("Location") != "/" || wrong.Body.Len() != 0 {
		t.Fatalf("a wrong passphrase answered %d %q %q", wrong.Code, wrong.Header().Get("Location"), wrong.Body.String())
	}
	opened := b.do(http.MethodPost, "/unlock", Origin, url.Values{"secret": {p}})
	proof := proofIn(opened)
	raw, err := base64.RawURLEncoding.DecodeString(proof)
	if opened.Code != http.StatusOK || err != nil || len(raw) != 32 {
		t.Fatalf("the unlock answered %d with the proof %q (%v)", opened.Code, proof, err)
	}
	ticketOf(t, opened, home)
	again := b.do(http.MethodPost, "/unlock", Origin, url.Values{"secret": {p}, "proof": {proof}})
	if proofIn(again) != "" || !strings.HasPrefix(again.Header().Get("Location"), home.address()) {
		t.Fatalf("an unlock of the unlocked box answered %d %q", again.Code, again.Header().Get("Location"))
	}
	answers := map[string]*httptest.ResponseRecorder{
		"the page":         b.do(http.MethodGet, "/", "", nil),
		"Open CYFR":        b.do(http.MethodPost, "/open", Origin, url.Values{"proof": {proof}}),
		"the code's POST":  b.do(http.MethodPost, "/recovery", Origin, url.Values{"proof": {proof}}),
		"a confirmation":   b.do(http.MethodGet, "/confirm?ref=cnr_x", "", nil),
		"a refused Origin": b.do(http.MethodPost, "/open", "https://evil.example", url.Values{"proof": {proof}}),
		"Lock":             b.do(http.MethodGet, "/lock", "", nil),
	}
	for name, w := range answers {
		if strings.Contains(w.Body.String(), proof) || strings.Contains(fmt.Sprint(w.Header()), proof) {
			t.Errorf("%s carries the proof", name)
		}
	}
}

// A key made before (Already have an account?) makes its own account
// only with its PIN: a wrong one makes nothing and hands over no proof;
// the right one hands over the proof the recovery code is shown to.
func TestServer_MakingTheAccountOfAKeyMadeBeforeAsksThePIN(t *testing.T) {
	home := newFakeHome(t)
	b := newBox(t, home, t.TempDir())
	p := b.shown()
	b.post("/make", url.Values{"secret": {p}, "again": {p}})
	if b.proof != "" || !strings.Contains(b.page(), "Add this box to your account") {
		t.Fatalf("making the key handed over %q, or shows:\n%s", b.proof, b.page())
	}
	for name, fields := range map[string]url.Values{
		"no passphrase":   {"name": {"alice"}},
		"a wrong one":     {"name": {"alice"}, "secret": {otherPassphrase(t, p)}},
		"a local program": {"name": {"alice"}, "proof": {""}},
	} {
		w := b.post("/create", fields)
		if w.Code != http.StatusSeeOther || w.Header().Get("Location") != "/" || w.Body.Len() != 0 || b.proof != "" ||
			b.shell.View().Page != PageEnroll || b.shell.View().RecoveryCode != "" || !strings.Contains(b.page(), "not this screen") {
			t.Fatalf("%s answered %d %q, the box shows %s", name, w.Code, w.Header().Get("Location"), b.shell.View().Page)
		}
	}
	made := b.post("/create", url.Values{"name": {"alice"}, "secret": {p}})
	code := b.shell.View().RecoveryCode
	if made.Code != http.StatusOK || b.proof == "" || code == "" || !strings.Contains(body(made), `<p class="code">`+code+`</p>`) {
		t.Fatalf("the account's making answered %d:\n%s", made.Code, body(made))
	}
	if strings.Contains(b.page(), code) {
		t.Fatal("a plain read shows the code")
	}
	b.post("/saved", nil)
	if !strings.Contains(b.page(), "CYFR is locked") {
		t.Fatalf("the made account does not ask the passphrase:\n%s", b.page())
	}
	ticketOf(t, b.post("/unlock", url.Values{"secret": {p}}), home)
}

// A page served from another loopback port is another origin: whatever it
// holds, the current proof included, every POST it sends is refused before
// anything acts, and no answer of the shell's sets a cookie, which
// 127.0.0.1 would send to every port.
func TestServer_AnotherLoopbackPortGetsNothing(t *testing.T) {
	home := newFakeHome(t)
	b := newBox(t, home, t.TempDir())
	p := setUpAndOpen(t, home, b)
	b.do(http.MethodGet, "/lock", "", nil)
	unlocked := b.post("/unlock", url.Values{"secret": {p}})
	proof := proofIn(unlocked)
	other := "http://127.0.0.1:7341"
	for route := range actions {
		ops := len(home.opsSeen())
		w := b.do(http.MethodPost, route, other, url.Values{"proof": {proof}})
		if w.Code != http.StatusForbidden || toHome(w, home) || len(home.opsSeen()) != ops {
			t.Errorf("%s from %s answered %d %q", route, other, w.Code, w.Header().Get("Location"))
		}
	}
	for _, w := range []*httptest.ResponseRecorder{unlocked, b.do(http.MethodGet, "/", "", nil), b.post("/open", url.Values{"proof": {proof}})} {
		if c := w.Header().Values("Set-Cookie"); len(c) != 0 {
			t.Errorf("an answer sets a cookie: %v", c)
		}
	}
}

// A proof from before a lock gets nothing: after a lock and a new unlock,
// only the new unlock's proof opens CYFR.
func TestServer_AProofFromBeforeALockGetsNothing(t *testing.T) {
	home := newFakeHome(t)
	b := newBox(t, home, t.TempDir())
	p := setUpAndOpen(t, home, b)
	b.do(http.MethodGet, "/lock", "", nil)
	before := proofIn(b.post("/unlock", url.Values{"secret": {p}}))
	b.do(http.MethodGet, "/lock", "", nil)
	after := proofIn(b.post("/unlock", url.Values{"secret": {p}}))
	if !b.shell.Unlocked() {
		t.Fatal("the second unlock did not unlock")
	}
	ops := len(home.opsSeen())
	w := b.do(http.MethodPost, "/open", Origin, url.Values{"proof": {before}})
	if w.Code != http.StatusSeeOther || w.Header().Get("Location") != "/" || w.Body.Len() != 0 || len(home.opsSeen()) != ops {
		t.Fatalf("the proof from before the lock answered %d %q", w.Code, w.Header().Get("Location"))
	}
	if before == after || after == "" {
		t.Fatalf("the unlocks' proofs %q and %q", before, after)
	}
	if ticket := ticketOf(t, b.do(http.MethodPost, "/open", Origin, url.Values{"proof": {after}}), home); ticket == "" {
		t.Fatal("the current proof opened nothing")
	}
}

var passphraseShape = regexp.MustCompile(`<p class="code">[a-z]+( [a-z]+){5}</p>`)

// A setup without a chip shows its passphrase only in the answer to the
// request that drew it: a plain local read shows none, before or after;
// another draw, by anyone, replaces it, and the setup takes only the last.
func TestServer_APlainReadShowsNoPassphrase(t *testing.T) {
	home := newFakeHome(t)
	b := newBox(t, home, t.TempDir())
	plain := b.do(http.MethodGet, "/", "", nil).Body.String()
	if m := passphraseShape.FindString(plain); m != "" || strings.Contains(plain, `action="/setup"`) ||
		!strings.Contains(plain, `<form method="post" action="/passphrase"><input type="hidden" name="proof"><button autofocus>Show the passphrase</button></form>`) {
		t.Fatalf("a plain read of the setup page shows the passphrase %q, or no way to show it:\n%s", m, plain)
	}
	drew := b.post("/passphrase", nil)
	p := codeShape.FindStringSubmatch(body(drew))[1]
	if drew.Code != http.StatusOK || !passphraseShape.MatchString(drew.Body.String()) || !strings.Contains(drew.Body.String(), `action="/setup"`) {
		t.Fatalf("Show the passphrase answered %d:\n%s", drew.Code, body(drew))
	}
	after := b.do(http.MethodGet, "/", "", nil).Body.String()
	if strings.Contains(after, p) || passphraseShape.MatchString(after) || !strings.Contains(after, `action="/setup"`) ||
		!strings.Contains(after, "If you did not write it down, show a new one") || !strings.Contains(after, ">Show a new passphrase</button>") {
		t.Fatalf("a plain read after the draw:\n%s", after)
	}
	other := b.do(http.MethodPost, "/passphrase", Origin, url.Values{"x": {"y"}})
	q := codeShape.FindStringSubmatch(body(other))[1]
	if q == p {
		t.Fatal("another draw answered the same passphrase")
	}
	refused := b.post("/setup", url.Values{"name": {"alice"}, "secret": {p}, "again": {p}})
	if refused.Code != http.StatusSeeOther || refused.Header().Get("Location") != "/" || strings.Contains(refused.Body.String(), q) {
		t.Fatalf("a setup with the replaced passphrase answered %d %q", refused.Code, refused.Header().Get("Location"))
	}
	if _, err := os.Stat(b.record); !os.IsNotExist(err) || !strings.Contains(b.page(), "not the passphrase shown last") || strings.Contains(b.page(), q) {
		t.Fatal("the replaced passphrase made a key, or the page says nothing, or shows the new one")
	}
	if w := b.post("/setup", url.Values{"name": {"alice"}, "secret": {q}, "again": {q}}); w.Code != http.StatusOK || proofIn(w) == "" {
		t.Fatalf("the last passphrase drawn did not set up: %d", w.Code)
	}
}

// A box whose chip keeps the PIN draws no passphrase for anyone: a draw
// answers the page, which still asks the six-digit PIN.
func TestServer_AChipBoxDrawsNoPassphrase(t *testing.T) {
	home := newFakeHome(t)
	b := newBox(t, home, t.TempDir())
	b.shell.cfg.Chip = func() bool { return true }
	w := b.do(http.MethodPost, "/passphrase", Origin, url.Values{"x": {"y"}})
	page := b.page()
	if w.Code != http.StatusSeeOther || w.Header().Get("Location") != "/" || w.Body.Len() != 0 || b.shell.passphrase != "" ||
		!strings.Contains(page, "Choose a six-digit PIN") || strings.Contains(page, `action="/passphrase"`) {
		t.Fatalf("a draw on a chip box answered %d %q:\n%s", w.Code, w.Header().Get("Location"), page)
	}
}

// forged is a request a local program sends naming the shell's Host and
// Origin, with no PIN and no proof.
func (b *box) forged(path string, fields url.Values) *httptest.ResponseRecorder {
	return b.do(http.MethodPost, path, Origin, fields)
}

// No request without the PIN that just opened the key or the current
// proof acts with what the shell holds for the page that typed it: the
// pending account's recovery key, its claim, its acceptance, its name.
// Each case sets the person's own flow to the state the action acts in,
// then a local program asks; the account service hears nothing.
func TestServer_NoActionUsesTheHeldKeysWithoutTheProof(t *testing.T) {
	type state struct {
		writes            int
		holder, accepted  string
		identifier, named string
	}
	read := func(home *fakeHome, b *box, name string) state {
		rec, _ := holder.Load(b.record)
		id := ""
		if rec != nil {
			id = rec.Identifier
		}
		pending := b.shell.View().Name
		return state{writes: home.accounts.Writes, holder: home.accounts.Holder(name), accepted: home.accounts.Accepted(id), identifier: id, named: pending}
	}
	cases := []struct {
		name   string
		reach  func(home *fakeHome, b *box)
		path   string
		fields url.Values
		claim  string
	}{
		{"the recovery code shown, a submit", func(home *fakeHome, b *box) { b.setUp("alice") },
			"/saved", url.Values{"x": {"y"}}, "alice"},
		{"a name taken meanwhile, another name", func(home *fakeHome, b *box) {
			b.setUp("alice")
			home.accounts.Hold("alice", "per_"+strings.Repeat("0", 64))
			b.post("/saved", nil)
		}, "/name", url.Values{"name": {"attacker-name"}}, "attacker-name"},
		{"the terms changed, their acceptance", func(home *fakeHome, b *box) {
			home.accounts.Policy = &account.Policy{Version: "2026-10", URL: "https://cyfr.example/terms"}
			b.page()
			p := b.shown()
			b.post("/setup", url.Values{"name": {"alice"}, "secret": {p}, "again": {p}, "accept": {"yes"}})
			home.accounts.Policy = &account.Policy{Version: "2026-11", URL: "https://cyfr.example/terms"}
			b.post("/saved", nil)
		}, "/saved", url.Values{"accept": {"yes"}}, "alice"},
	}
	for _, c := range cases {
		home := newFakeHome(t)
		b := newBox(t, home, t.TempDir())
		c.reach(home, b)
		before := read(home, b, c.claim)
		b.forged(c.path, c.fields)
		if after := read(home, b, c.claim); after != before {
			t.Errorf("%s: a local program's %s changed %+v to %+v", c.name, c.path, before, after)
		}
	}
}

// A restarted box finishes its account only with that account's own
// recovery code: one made from the pending identifier with any other
// secret, as anyone can make one, a malformed one and another account's
// are refused before anything is sent, and none is handed the proof.
func TestServer_ResumeTakesOnlyTheAccountsOwnCode(t *testing.T) {
	home := newFakeHome(t)
	dir := t.TempDir()
	b := newBox(t, home, dir)
	b.setUp("alice")
	code := b.recovery()
	home.accounts.Down = true
	b.post("/saved", nil)
	home.accounts.Down = false
	again := newBox(t, home, dir)
	identifier, _, err := account.DecodeRecoveryCode(code)
	if err != nil {
		t.Fatal(err)
	}
	invented := func(id string) string {
		secret := make([]byte, 32)
		for i := range secret {
			secret[i] = byte(i + 7)
		}
		c, err := account.EncodeRecoveryCode(id, secret)
		if err != nil {
			t.Fatal(err)
		}
		return c
	}
	for name, c := range map[string]struct{ code, says string }{
		"the identifier with an invented secret": {invented(identifier), "not this account's"},
		"another account's code":                 {invented("per_" + strings.Repeat("ab", 32)), "another account's"},
		"no code at all":                         {"CYFR-0000", "not a recovery code"},
	} {
		writes := home.accounts.Writes
		w := again.forged("/resume", url.Values{"code": {c.code}})
		if proofIn(w) != "" || home.accounts.Writes != writes || again.shell.View().Page != PageResume || !strings.Contains(again.page(), c.says) {
			t.Errorf("%s: answered %d with proof %q, writes %d to %d, page %s", name, w.Code, proofIn(w), writes, home.accounts.Writes, again.shell.View().Page)
		}
	}
	writes := home.accounts.Writes
	w := again.forged("/resume", url.Values{"code": {code}})
	if proofIn(w) == "" || home.accounts.Writes == writes || again.shell.View().Page != PageLocked {
		t.Fatalf("the account's own code answered %d with proof %q, writes %d to %d", w.Code, proofIn(w), writes, home.accounts.Writes)
	}
}

// A drawn confirmation's preview and reference go only to the request that
// names its reference; a plain read shows neither.
func TestServer_APlainReadShowsNoConfirmation(t *testing.T) {
	_, b, _ := confirmable(t)
	drawn := b.do(http.MethodGet, "/confirm?ref=cnr_1", "", nil).Body.String()
	if !strings.Contains(drawn, "Household") || !strings.Contains(drawn, `value="cnr_1"`) {
		t.Fatalf("the drawing request is not shown its confirmation:\n%s", drawn)
	}
	plain := b.do(http.MethodGet, "/", "", nil).Body.String()
	if strings.Contains(plain, "Household") || strings.Contains(plain, "cnr_1") || strings.Contains(plain, "vault.create") ||
		!strings.Contains(plain, "<h1>A confirmation is open</h1>") {
		t.Fatalf("a plain read with a confirmation drawn:\n%s", plain)
	}
	other := b.do(http.MethodGet, "/confirm?ref=cnr_2", "", nil).Body.String()
	if strings.Contains(other, "Household") || strings.Contains(other, "cnr_1") {
		t.Fatalf("a request naming another reference is shown the drawn one:\n%s", other)
	}
}
