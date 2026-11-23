// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package shell

import (
	"context"
	"errors"
	"html"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/cyfr/codex/internal/account"
	"github.com/cyfr/codex/internal/disk"
)

// promptly is how long what waits for nothing may take here: far over what
// it takes, and under every bound it could have waited out instead.
const promptly = 2500 * time.Millisecond

// gate holds what passes it, while it is shut, until it opens.
type gate struct {
	t       *testing.T
	mu      sync.Mutex
	opened  chan struct{}
	arrived chan struct{}
	count   atomic.Int32
}

func newGate(t *testing.T) *gate {
	return &gate{t: t, arrived: make(chan struct{}, 128)}
}

// shut holds from now on. It opens as the test ends, before anything made
// earlier is cleaned up, whose own lock could wait for what it holds.
func (g *gate) shut() {
	g.t.Cleanup(g.open)
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.opened == nil {
		g.opened = make(chan struct{})
	}
}

func (g *gate) open() {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.opened != nil {
		close(g.opened)
		g.opened = nil
	}
}

func (g *gate) pass(ctx context.Context) error {
	g.mu.Lock()
	opened := g.opened
	g.mu.Unlock()
	g.count.Add(1)
	if opened == nil {
		return nil
	}
	g.arrived <- struct{}{}
	select {
	case <-opened:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (g *gate) reached(t *testing.T) {
	t.Helper()
	select {
	case <-g.arrived:
	case <-time.After(10 * time.Second):
		t.Fatal("what was to be blocked was never reached")
	}
}

type gatedTransport struct {
	base http.RoundTripper
	gate *gate
	only func(*http.Request) bool
}

func (g gatedTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	if g.only(r) {
		if err := g.gate.pass(r.Context()); err != nil {
			return nil, err
		}
	}
	return g.base.RoundTrip(r)
}

// gated has the shell's client held at g where only says.
func gated(g *gate, only func(*http.Request) bool) func(*Config) {
	return func(c *Config) {
		client := *c.Client
		base := client.Transport
		if base == nil {
			base = http.DefaultTransport
		}
		client.Transport = gatedTransport{base: base, gate: g, only: only}
		c.Client = &client
	}
}

func theDial(r *http.Request) bool { return strings.HasSuffix(r.URL.Path, "/device/websocket") }

// returns runs f, which is to wait for nothing held.
func returns(t *testing.T, what string, f func()) {
	t.Helper()
	done := make(chan struct{})
	go func() {
		defer close(done)
		f()
	}()
	select {
	case <-done:
	case <-time.After(promptly):
		t.Fatalf("%s waited", what)
	}
}

func becomesTrue(t *testing.T, what string, ok func() bool) {
	t.Helper()
	for deadline := time.Now().Add(10 * time.Second); !ok(); {
		if time.Now().After(deadline) {
			t.Fatalf("never: %s", what)
		}
		time.Sleep(5 * time.Millisecond) // sleep-ok: polls an observable condition
	}
}

// waiters answers what receives as an action begins to wait for sh, which
// another holds. It is set before that action begins.
func waiters(sh *Shell) <-chan struct{} {
	waiting := make(chan struct{}, 128)
	sh.mu.waiting = func() {
		select {
		case waiting <- struct{}{}:
		default:
		}
	}
	return waiting
}

func waits(t *testing.T, what string, waiting <-chan struct{}) {
	t.Helper()
	select {
	case <-waiting:
	case <-time.After(10 * time.Second):
		t.Fatalf("%s never waited for the shell", what)
	}
}

// aloud is b.page without the test's own helpers, for a goroutine.
func (b *box) aloud() string {
	w := httptest.NewRecorder()
	b.srv.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "http://"+Listen+"/", nil))
	return html.UnescapeString(w.Body.String())
}

// neverConnected is a box on an account of the person's that has said no
// hello: locked, its first unlock reads the setup token and dials.
func neverConnected(t *testing.T, home *fakeHome, edit ...func(*Config)) (*box, string) {
	t.Helper()
	identifier, dev, _ := home.account(t, "mira")
	b := newBoxAt(t, home, t.TempDir(), home.accounts.URL(), edit...)
	p := b.shown()
	b.post("/make", url.Values{"secret": {p}, "again": {p}})
	b.shell.mu.Lock()
	pub := b.shell.rec.PublicKey
	b.shell.mu.Unlock()
	home.approve(t, identifier, dev, pub)
	b.post("/enroll", url.Values{"name": {"mira"}})
	if v, ok := b.shell.pageView(t.Context(), nil); !ok || v.Page != PageLocked {
		t.Fatalf("the approved box shows %s: %s", v.Page, v.Notice)
	}
	return b, p
}

func standing(home *fakeHome) int {
	home.mu.Lock()
	defer home.mu.Unlock()
	return home.standing
}

// No page waits for the reading of whether the CYFR answers: each shows
// what the last finished one said, "starting" before one has.
func TestRender_NoPageWaitsForAReading(t *testing.T) {
	const why = "This screen stays locked because it cannot tell when this device goes to sleep."
	for name, c := range map[string]struct {
		setup     bool
		unwatched string
		first     string
		then      string
	}{
		"setup":     {true, "", "CYFR is starting", `action="/passphrase"`},
		"locked":    {false, "", "CYFR is starting", `action="/unlock"`},
		"unwatched": {false, why, why, why},
	} {
		t.Run(name, func(t *testing.T) {
			home := newFakeHome(t)
			var lost atomic.Bool
			watched := func(cfg *Config) {
				cfg.Unwatched = func() string {
					if lost.Load() {
						return c.unwatched
					}
					return ""
				}
			}
			var b *box
			if c.setup {
				b = newBoxAt(t, home, t.TempDir(), home.accounts.URL(), watched)
			} else {
				b, _ = neverConnected(t, home, watched)
			}
			lost.Store(true)
			g := newGate(t)
			g.shut()
			var answers atomic.Bool
			answers.Store(true)
			b.srv.Reachable = func(context.Context) error {
				_ = g.pass(context.Background())
				if answers.Load() {
					return nil
				}
				return errors.New("no answer yet")
			}
			var page string
			returns(t, "the first page", func() { page = b.aloud() })
			if !strings.Contains(page, c.first) || !strings.Contains(page, `http-equiv="refresh"`) {
				t.Fatalf("before any reading the page is\n%s", page)
			}
			g.reached(t)
			g.open()
			becomesTrue(t, "the page shows what the reading said", func() bool { return strings.Contains(b.aloud(), c.then) })

			becomesTrue(t, "no reading is in flight", func() bool {
				b.srv.lastMu.Lock()
				defer b.srv.lastMu.Unlock()
				return !b.srv.reading
			})
			g.shut()
			answers.Store(false)
			returns(t, "a page beside the next reading", func() { page = b.aloud() })
			if !strings.Contains(page, c.then) {
				t.Fatalf("beside the next reading the page is not the last one's:\n%s", page)
			}
			g.reached(t)
			g.open()
			becomesTrue(t, "the page follows a reading that says no", func() bool { return strings.Contains(b.aloud(), c.first) })
		})
	}
}

func TestRender_OneReadingAtATime(t *testing.T) {
	home := newFakeHome(t)
	b, _ := neverConnected(t, home)
	g := newGate(t)
	g.shut()
	b.srv.Reachable = func(context.Context) error { return g.pass(context.Background()) }
	returns(t, "many pages", func() {
		var all sync.WaitGroup
		for range 25 {
			all.Go(func() { b.aloud() })
		}
		all.Wait()
	})
	g.reached(t)
	if n := g.count.Load(); n != 1 {
		t.Fatalf("25 pages began %d readings", n)
	}
	g.open()
	becomesTrue(t, "a later page begins the next reading", func() bool {
		b.aloud()
		return g.count.Load() > 1
	})
}

// A screen's setup page waits for neither the account service nor a lock
// for it, and its first form names the terms.
func TestRender_TheTermsAreReadBesideThePage(t *testing.T) {
	home := newFakeHome(t)
	home.accounts.Policy = &account.Policy{Version: "2026-10", URL: "https://cyfr.example/terms"}
	g := newGate(t)
	b := newBoxAt(t, home, t.TempDir(), home.accounts.URL(), gated(g, func(r *http.Request) bool { return !theDial(r) }))
	b.srv.Reachable = func(context.Context) error { return nil }
	g.shut()
	var page string
	returns(t, "the setup page", func() { page = b.aloud() })
	if !strings.Contains(page, "CYFR is starting") {
		t.Fatalf("a form before its terms were read:\n%s", page)
	}
	g.reached(t)
	g.open()
	becomesTrue(t, "the setup form", func() bool {
		page = b.aloud()
		return strings.Contains(page, `action="/setup"`) || strings.Contains(page, `action="/passphrase"`)
	})
	if !b.shell.shown.Load().configured {
		t.Fatal("the first form came before the terms were read")
	}
	if drawn := body(b.post("/passphrase", nil)); !strings.Contains(drawn, "I accept the terms at https://cyfr.example/terms") {
		t.Fatalf("the form names no terms:\n%s", drawn)
	}
}

// The terms' reading holds nothing of the shell as it waits, so a lock
// waits for none of it, even one deaf to the lock.
func TestRender_ALockWaitsForNoTermsReading(t *testing.T) {
	home := newFakeHome(t)
	g := newGate(t)
	b := newBoxAt(t, home, t.TempDir(), home.accounts.URL(), gated(g, func(r *http.Request) bool { return !theDial(r) }))
	b.srv.Reachable = func(context.Context) error { return nil }
	makeDeaf(b.shell)
	g.shut()
	b.aloud()
	g.reached(t)
	returns(t, "the lock", func() { b.shell.Lock("") })
	g.open()
}

// No page waits for an action in flight, which holds the shell through
// Docker and the dial.
func TestRender_NoPageWaitsForAnActionInFlight(t *testing.T) {
	home := newFakeHome(t)
	g := newGate(t)
	b, p := neverConnected(t, home, gated(g, theDial))
	g.shut()
	unlocking := make(chan struct{})
	go func() {
		defer close(unlocking)
		b.post("/unlock", url.Values{"secret": {p}})
	}()
	g.reached(t)
	var page, confirm, passkey string
	returns(t, "a page", func() { page = b.aloud() })
	returns(t, "the confirm page", func() { confirm = body(b.do(http.MethodGet, "/confirm?ref=cnr_1", "", nil)) })
	returns(t, "the passkey page", func() { passkey = body(b.do(http.MethodGet, "/passkey?ref=pkw_1", "", nil)) })
	returns(t, "whether it is unlocked", func() { b.shell.Unlocked() })
	if !strings.Contains(page, `action="/unlock"`) || !strings.Contains(confirm, unlockToConfirm) || !strings.Contains(passkey, unlockToApprove) {
		t.Fatalf("beside an unlock in flight:\n%s\n%s\n%s", page, confirm, passkey)
	}
	g.open()
	<-unlocking
}

// A lock waits for no unlock in flight, whichever way it is asked, and the
// person is shown the lock page with no sentence of a failure.
func TestLock_WaitsForNoUnlockInFlight(t *testing.T) {
	ways := map[string]func(b *box){
		"the shell's": func(b *box) { b.shell.Lock(suspendedHere) },
		"Prism's":     func(b *box) { b.do(http.MethodGet, "/lock", "", nil) },
		"the page's":  func(b *box) { b.do(http.MethodPost, "/lock", Origin, url.Values{}) },
	}
	for where, hold := range map[string]func(*gate) func(*Config){
		"in the token's reading": func(g *gate) func(*Config) {
			return func(c *Config) {
				read := c.SetupToken
				c.SetupToken = func(ctx context.Context) (string, http.RoundTripper) {
					if g.pass(ctx) != nil {
						return "", nil
					}
					return read(ctx)
				}
			}
		},
		"in the dial": func(g *gate) func(*Config) { return gated(g, theDial) },
	} {
		for way, lock := range ways {
			t.Run(where+", "+way, func(t *testing.T) {
				home := newFakeHome(t)
				g := newGate(t)
				b, p := neverConnected(t, home, hold(g))
				g.shut()
				answered := make(chan *httptest.ResponseRecorder, 1)
				go func() { answered <- b.post("/unlock", url.Values{"secret": {p}}) }()
				g.reached(t)
				returns(t, "the lock", func() { lock(b) })
				var w *httptest.ResponseRecorder
				returns(t, "the unlock a lock cut short", func() { w = <-answered })
				if w.Code != http.StatusSeeOther || w.Header().Get("Location") != "/" || proofIn(w) != "" {
					t.Fatalf("the unlock cut short answered %d %q:\n%s", w.Code, w.Header().Get("Location"), body(w))
				}
				page := b.page()
				if b.shell.Unlocked() || !strings.Contains(page, `action="/unlock"`) || strings.Contains(page, `class="notice"`) {
					t.Fatalf("after the lock the page is\n%s", page)
				}
				if len(home.hellosSeen()) != 0 || standing(home) != 0 {
					t.Fatal("an unlock cut short reached the CYFR")
				}
				g.open()
				ticketOf(t, b.post("/unlock", url.Values{"secret": {p}}), home)
			})
		}
	}
}

const suspendedHere = "Locked as this device went to sleep."

// An unlock a lock came before opens nothing after it: one that was all but
// done, its handshake's last step deaf to the lock, and one that had not
// yet taken the shell.
func TestLock_AnUnlockBegunBeforeItNeverOpensAfterIt(t *testing.T) {
	// atLastStep is a box whose unlock is held, deaf to a lock, as the
	// handshake's last write is to go.
	atLastStep := func(t *testing.T, home *fakeHome, g *gate) (*box, string) {
		var last atomic.Bool
		return neverConnected(t, home, func(c *Config) {
			token, detect := c.SetupToken, c.Detect
			c.SetupToken = func(ctx context.Context) (string, http.RoundTripper) {
				defer last.Store(true)
				return token(ctx)
			}
			c.Detect = func(dir string) disk.Report {
				if last.Swap(false) {
					_ = g.pass(context.Background())
				}
				return detect(dir)
			}
		})
	}
	t.Run("as its handshake's last write got out", func(t *testing.T) {
		home := newFakeHome(t)
		g := newGate(t)
		b, p := atLastStep(t, home, g)
		makeDeaf(b.shell)
		g.shut()
		proof := make(chan string, 1)
		go func() { proof <- b.shell.unlock(context.Background(), []byte(p)) }()
		g.reached(t)
		// The lock comes too late to cancel the write: it finds nothing
		// left to cancel, and waits for the shell.
		locked := make(chan struct{})
		go func() {
			defer close(locked)
			b.shell.Lock(suspendedHere)
		}()
		becomesTrue(t, "the lock waits", func() bool { return lockComing(b.shell) })
		g.open()
		<-proof
		<-locked
		becomesTrue(t, "no channel stands", func() bool { return standing(home) == 0 })
		if page := b.page(); b.shell.Unlocked() || b.restarts.Load() != 0 || strings.Contains(page, `class="notice"`) {
			t.Fatalf("it opened after the lock:\n%s", page)
		}
	})
	t.Run("at the handshake's last step", func(t *testing.T) {
		home := newFakeHome(t)
		g := newGate(t)
		b, p := atLastStep(t, home, g)
		g.shut()
		answered := make(chan *httptest.ResponseRecorder, 1)
		go func() { answered <- b.post("/unlock", url.Values{"secret": {p}}) }()
		g.reached(t)
		locked := make(chan struct{})
		go func() {
			defer close(locked)
			b.shell.Lock(suspendedHere)
		}()
		becomesTrue(t, "the lock waits", func() bool { return lockComing(b.shell) })
		g.open()
		<-locked
		if w := <-answered; w.Code != http.StatusSeeOther || proofIn(w) != "" {
			t.Fatalf("the unlock answered %d:\n%s", w.Code, body(w))
		}
		becomesTrue(t, "no channel stands", func() bool { return standing(home) == 0 })
		if b.shell.Unlocked() || slices.Contains(home.opsSeen(), "session.unlock") || strings.Contains(b.page(), `class="notice"`) {
			t.Fatalf("it opened after the lock:\n%s", b.page())
		}
	})
	t.Run("before it took the shell", func(t *testing.T) {
		home := newFakeHome(t)
		b, p := neverConnected(t, home)
		ctx, done := b.shell.act(t.Context())
		defer done()
		b.shell.Lock("")
		if proof := b.shell.unlock(ctx, []byte(p)); proof != "" || b.shell.Unlocked() || len(home.hellosSeen()) != 0 || b.shell.shownView().Notice != "" {
			t.Fatal("an unlock begun before the lock ran after it")
		}
	})
	t.Run("beginning after the lock", func(t *testing.T) {
		home := newFakeHome(t)
		b := newBox(t, home, t.TempDir())
		setUpAndOpen(t, home, b)
		ctx, done := b.shell.act(t.Context())
		defer done()
		b.shell.Lock(suspendedHere)
		b.shell.Begin(ctx)
		if page := b.page(); !strings.Contains(page, suspendedHere) {
			t.Fatalf("what began before the lock erased the lock's sentence:\n%s", page)
		}
	})
	t.Run("begun as a lock waited", func(t *testing.T) {
		home := newFakeHome(t)
		b, p := neverConnected(t, home)
		locked, _ := b.shell.end(nil)
		defer locked()
		w := b.post("/unlock", url.Values{"secret": {p}})
		if w.Code != http.StatusSeeOther || proofIn(w) != "" || b.shell.Unlocked() || len(home.hellosSeen()) != 0 {
			t.Fatalf("an unlock begun as a lock waited answered %d:\n%s", w.Code, body(w))
		}
	})
	t.Run("as it waited to begin", func(t *testing.T) {
		home := newFakeHome(t)
		b := newBox(t, home, t.TempDir())
		setUpAndOpen(t, home, b)
		waiting := waiters(b.shell)
		b.shell.mu.Lock()
		answered := make(chan *httptest.ResponseRecorder, 1)
		go func() { answered <- b.post("/open", nil) }()
		waits(t, "the action", waiting)
		locked := make(chan struct{})
		go func() {
			defer close(locked)
			b.shell.Lock(suspendedHere)
		}()
		becomesTrue(t, "the lock waits", func() bool { return lockComing(b.shell) })
		b.shell.mu.Unlock()
		<-locked
		if w := <-answered; w.Code != http.StatusSeeOther || w.Header().Get("Location") != "/" {
			t.Fatalf("the action answered %d %q", w.Code, w.Header().Get("Location"))
		}
		if page := b.page(); b.shell.Unlocked() || !strings.Contains(page, suspendedHere) {
			t.Fatalf("the lock's own sentence was lost:\n%s", page)
		}
	})
}

// An unlock that finished first is locked by the lock after it, whether
// its session was asked, reserved or handed over: no session lives on.
func TestLock_AfterAnUnlockFinishedLeavesNoSession(t *testing.T) {
	for name, c := range map[string]struct {
		holds  bool
		proven bool
		locked []string
	}{
		"as it asks the session":    {true, false, nil},
		"as the session is spent":   {true, true, []string{"ses_1"}},
		"with the ticket delivered": {false, false, []string{"ses_1"}},
	} {
		t.Run(name, func(t *testing.T) {
			home := newFakeHome(t)
			b, p := neverConnected(t, home)
			g := newGate(t)
			if c.holds {
				g.shut()
				home.mu.Lock()
				home.answering = func(op string, args map[string]any) {
					if _, proven := args["proof"]; op == "session.unlock" && proven == c.proven {
						_ = g.pass(context.Background())
					}
				}
				home.mu.Unlock()
			}
			answered := make(chan *httptest.ResponseRecorder, 1)
			go func() { answered <- b.post("/unlock", url.Values{"secret": {p}}) }()
			var w *httptest.ResponseRecorder
			if c.holds {
				g.reached(t)
			} else {
				w = <-answered
				ticketOf(t, w, home)
			}
			locked := make(chan struct{})
			go func() {
				defer close(locked)
				b.shell.Lock(suspendedHere)
			}()
			if c.holds {
				returns(t, "the unlock a lock cut short", func() { w = <-answered })
				if strings.Contains(w.Header().Get("Location")+w.Body.String(), "/auth/device/complete") {
					t.Fatal("it handed a ticket over after the lock")
				}
				g.open()
			}
			<-locked
			becomesTrue(t, "no channel stands", func() bool { return standing(home) == 0 })
			home.mu.Lock()
			got := slices.Clone(home.locked)
			home.mu.Unlock()
			if b.shell.Unlocked() || !slices.Equal(got, c.locked) || b.restarts.Load() != 1 {
				t.Fatalf("unlocked %v, sessions locked %v, restarts %d", b.shell.Unlocked(), got, b.restarts.Load())
			}
			if page := b.page(); !strings.Contains(page, suspendedHere) || strings.Contains(page, "could not be reached") {
				t.Fatalf("after the lock the page is\n%s", page)
			}
		})
	}
}

// The lock a channel's end makes waits for no decision in flight either.
func TestLock_AChannelsEndWaitsForNoWorkInFlight(t *testing.T) {
	home := newFakeHome(t)
	g := newGate(t)
	b := newBoxAt(t, home, t.TempDir(), home.accounts.URL(), gated(g, func(r *http.Request) bool { return !theDial(r) }))
	p := setUpAndOpen(t, home, b)
	key := newPasskey(t)
	home.mu.Lock()
	home.waiting["pkw_1"] = waitingPasskey("pkw_1", key)
	home.mu.Unlock()
	b.do(http.MethodGet, "/passkey?ref=pkw_1", "", nil)
	g.shut()
	decided := make(chan *httptest.ResponseRecorder, 1)
	go func() {
		decided <- b.post("/passkey/decide", url.Values{"ref": {"pkw_1"}, "key": {keyDigest(key)}, "decision": {"approve"}, "secret": {p}})
	}()
	g.reached(t)
	home.closeChannels(4403)
	var w *httptest.ResponseRecorder
	returns(t, "the decision the channel's end cut short", func() { w = <-decided })
	if w.Code != http.StatusSeeOther {
		t.Fatalf("the decision cut short answered %d:\n%s", w.Code, body(w))
	}
	becomesTrue(t, "it locked", func() bool { return !b.shell.Unlocked() })
	if page := b.page(); !strings.Contains(page, "it was removed, CYFR does not admit your account") {
		t.Fatalf("the lock page does not say why the channel ended:\n%s", page)
	}
}

// A channel that a lock's cut ended, as a write cut short ends it, is that
// lock's and no failure to reach the CYFR.
func TestLock_AChannelItsCutEndedIsNoFailure(t *testing.T) {
	home := newFakeHome(t)
	b := newBox(t, home, t.TempDir())
	setUpAndOpen(t, home, b)
	b.shell.mu.Lock()
	ch := b.shell.ch
	b.shell.mu.Unlock()
	locked, _ := b.shell.end(nil)
	defer locked()
	home.closeChannels(1011)
	<-ch.Done()
	b.shell.Lock(suspendedHere)
	if page := b.page(); b.shell.Unlocked() || !strings.Contains(page, suspendedHere) || strings.Contains(page, "could not be reached") {
		t.Fatalf("a lock's cut is told as a failure:\n%s", page)
	}
}

// While a lock tells the CYFR, which may take it seconds, the page is the
// lock page already.
func TestLock_APageBesideItsTellingIsTheLockPage(t *testing.T) {
	home := newFakeHome(t)
	b := newBox(t, home, t.TempDir())
	setUpAndOpen(t, home, b)
	g := newGate(t)
	g.shut()
	home.mu.Lock()
	home.answering = func(op string, _ map[string]any) {
		if op == "session.lock" {
			_ = g.pass(context.Background())
		}
	}
	home.mu.Unlock()
	locked := make(chan struct{})
	go func() {
		defer close(locked)
		b.shell.Lock(suspendedHere)
	}()
	g.reached(t)
	var page string
	returns(t, "the page", func() { page = b.aloud() })
	if !strings.Contains(page, `action="/unlock"`) || !strings.Contains(page, suspendedHere) {
		t.Fatalf("beside the lock's telling the page is\n%s", page)
	}
	g.open()
	<-locked
}

// A confirmation a lock cut short is told neither as done nor as failed.
func TestLock_AConfirmationItCutShortSaysNeitherDoneNorFailed(t *testing.T) {
	home, b, p := confirmable(t)
	b.do(http.MethodGet, "/confirm?ref=cnr_1", "", nil)
	g := newGate(t)
	g.shut()
	home.mu.Lock()
	home.answering = func(op string, _ map[string]any) {
		if op == "confirmation.request" {
			_ = g.pass(context.Background())
		}
	}
	home.mu.Unlock()
	decided := make(chan *httptest.ResponseRecorder, 1)
	go func() {
		decided <- b.post("/confirm/decide", url.Values{"ref": {"cnr_1"}, "decision": {"confirm"}, "secret": {p}})
	}()
	g.reached(t)
	locked := make(chan struct{})
	go func() {
		defer close(locked)
		b.shell.Lock(suspendedHere)
	}()
	var w *httptest.ResponseRecorder
	returns(t, "the confirmation a lock cut short", func() { w = <-decided })
	if w.Code != http.StatusSeeOther || strings.Contains(w.Body.String(), "Done") {
		t.Fatalf("the confirmation cut short answered %d:\n%s", w.Code, body(w))
	}
	g.open()
	<-locked
	if page := b.page(); !strings.Contains(page, suspendedHere) {
		t.Fatalf("after the lock the page is\n%s", page)
	}
}

// A write a cancellation meets finishes, and the channel is there for the
// lock's proofs after it, written after it.
func TestLock_ACancelledIntentLeavesTheChannelToTheLock(t *testing.T) {
	home := newFakeHome(t)
	g := newGate(t)
	b := newBoxAt(t, home, t.TempDir(), home.accounts.URL(), func(c *Config) {
		client := *c.Client
		base := client.Transport
		if base == nil {
			base = http.DefaultTransport
		}
		client.Transport = slowWrites{base: base, gate: g}
		c.Client = &client
	})
	setUpAndOpen(t, home, b)
	b.shell.mu.Lock()
	ch := b.shell.ch
	b.shell.mu.Unlock()
	g.shut()
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	called := make(chan struct{})
	go func() {
		defer close(called)
		_, _ = ch.Call(ctx, "confirmation.pending", map[string]any{"request": "cnr_1"})
	}()
	g.reached(t)
	cancel()
	returns(t, "the cancelled intent", func() { <-called })
	if len(ch.writing) != 1 {
		t.Fatal("a write still under way gave its turn up, so the next intent could overtake it")
	}
	locked := make(chan struct{})
	go func() {
		defer close(locked)
		b.shell.Lock(suspendedHere)
	}()
	becomesTrue(t, "the lock began", func() bool { return lockComing(b.shell) })
	g.open()
	<-locked
	ops := home.opsSeen()
	home.mu.Lock()
	defer home.mu.Unlock()
	if !slices.Equal(home.locked, []string{"ses_1"}) || len(ops) < 2 || !slices.Equal(ops[len(ops)-2:], []string{"confirmation.pending", "session.lock"}) {
		t.Fatalf("the lock after it retired %v, the CYFR having read %v", home.locked, ops)
	}
}

// slowWrites holds the device channel's writes at gate, until it opens or
// the connection closes.
type slowWrites struct {
	base http.RoundTripper
	gate *gate
}

func (s slowWrites) RoundTrip(r *http.Request) (*http.Response, error) {
	resp, err := s.base.RoundTrip(r)
	if err != nil || !theDial(r) {
		return resp, err
	}
	conn, ok := resp.Body.(io.ReadWriteCloser)
	if !ok {
		return resp, nil
	}
	closed, closing := context.WithCancel(context.Background())
	resp.Body = &slowConn{ReadWriteCloser: conn, gate: s.gate, closed: closed, closing: closing}
	return resp, nil
}

type slowConn struct {
	io.ReadWriteCloser
	gate    *gate
	closed  context.Context
	closing context.CancelFunc
}

func (c *slowConn) Write(p []byte) (int, error) {
	if err := c.gate.pass(c.closed); err != nil {
		return 0, err
	}
	return c.ReadWriteCloser.Write(p)
}

func (c *slowConn) Close() error {
	c.closing()
	return c.ReadWriteCloser.Close()
}

// An action its client cancelled before a lock changes nothing after it:
// the cancellation's cause hides no lock.
func TestLock_AnActionCancelledFirstLeavesTheLocksSentence(t *testing.T) {
	home := newFakeHome(t)
	b := newBox(t, home, t.TempDir())
	setUpAndOpen(t, home, b)
	parent, cancel := context.WithCancel(t.Context())
	defer cancel()
	ctx, done := b.shell.act(parent)
	defer done()
	cancel()
	b.shell.Lock(suspendedHere)
	b.shell.Begin(ctx)
	if got := b.shell.shownView().Notice; got != suspendedHere {
		t.Fatalf("an action from before the lock overwrote its sentence: %q", got)
	}
}

// An action whose time ran out waits for the shell no longer.
func TestLock_AnExpiredActionStopsWaitingForTheShell(t *testing.T) {
	home := newFakeHome(t)
	b := newBox(t, home, t.TempDir())
	waiting := waiters(b.shell)
	b.shell.mu.Lock()
	defer b.shell.mu.Unlock()
	over := newExpiring()
	ctx, done := b.shell.act(over)
	defer done()
	began := make(chan struct{})
	go func() {
		defer close(began)
		b.shell.Begin(ctx)
	}()
	waits(t, "the action", waiting)
	over.expire()
	returns(t, "the expired action", func() { <-began })
	if !waitedOut(ctx) {
		t.Fatal("the wait's own failure was not seen")
	}
}
