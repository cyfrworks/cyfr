// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package shell

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"io"
	"maps"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/cyfr/codex/internal/account"
	"github.com/cyfr/codex/internal/disk"
	"github.com/cyfr/codex/internal/holder"
)

// deafEnd is a generation's end that reaches no context: work in flight
// goes on and succeeds as if the lock's cancellation came too late. What
// is left to stop it changing anything is the comparison alone.
type deafEnd struct {
	context.Context
	over  atomic.Bool
	never chan struct{}
}

func (d *deafEnd) Done() <-chan struct{} { return d.never }

func (d *deafEnd) Err() error {
	if d.over.Load() {
		return context.Canceled
	}
	return nil
}

// makeDeaf makes sh's current generation one whose end is deaf.
func makeDeaf(sh *Shell) {
	d := &deafEnd{Context: context.Background(), never: make(chan struct{})}
	sh.genMu.Lock()
	defer sh.genMu.Unlock()
	sh.gen = &generation{ended: d, end: func() { d.over.Store(true) }}
}

func lockComing(sh *Shell) bool {
	sh.genMu.Lock()
	defer sh.genMu.Unlock()
	return sh.gen.locks > 0
}

// wholeState is everything of a shell an action can change, on disk too.
// The caller holds the shell, or is all that runs on it.
func wholeState(t *testing.T, b *box) string {
	s := b.shell
	asJSON := func(v any) string {
		raw, err := json.Marshal(v)
		if err != nil {
			t.Fatalf("the shell's state: %v", err)
		}
		return string(raw)
	}
	var lines []string
	add := func(name string, v any) { lines = append(lines, fmt.Sprintf("%s=%v", name, v)) }
	add("rec", asJSON(s.rec))
	add("here", asJSON(s.here))
	add("key held", s.key != nil)
	add("channel", fmt.Sprintf("%p", s.ch))
	add("open", s.open.Load())
	add("lock proofs", asJSON(s.locks))
	add("notice", s.notice)
	add("passphrase", s.passphrase)
	if m := s.making; m != nil {
		add("making", asJSON(m.attempt))
		add("making's key", fmt.Sprintf("%x", []byte(m.key)))
		add("making's rest", fmt.Sprint(m.code, m.saved, m.taken))
	}
	add("unfinished", asJSON(s.unfinished))
	add("terms", asJSON(s.terms))
	add("configured", s.configured)
	add("confirm", asJSON(s.confirm))
	add("passkey", asJSON(s.passkey))
	add("proof", fmt.Sprintf("%x", s.proof))
	for _, file := range []string{b.record, filepath.Join(b.dir, "client.json"), filepath.Join(b.dir, "attempt.json")} {
		raw, err := os.ReadFile(file)
		add(filepath.Base(file), fmt.Sprint(string(raw), os.IsNotExist(err)))
	}
	return strings.Join(lines, "\n")
}

func stateDiff(a, b string) string {
	x, y := strings.Split(a, "\n"), strings.Split(b, "\n")
	var out []string
	for _, l := range x {
		if !slices.Contains(y, l) {
			out = append(out, "was "+l)
		}
	}
	for _, l := range y {
		if !slices.Contains(x, l) {
			out = append(out, "now "+l)
		}
	}
	return strings.Join(out, "\n")
}

// points are where a test can end a generation inside an action: at each
// release of the shell, request, reading of the key's record, opening of
// the key, and reading of this machine, the setup token and the clock.
type points struct {
	b    *box
	on   bool
	seen int
	at   int
	hit  func(point string)
	// sent is every request and intent of the box's, counted throughout.
	sent atomic.Int32
}

func (p *points) reach(point string) {
	if !p.on {
		return
	}
	p.seen++
	if p.hit != nil && p.seen == p.at {
		p.on = false
		p.hit(point)
	}
}

type pointTransport struct {
	base http.RoundTripper
	p    *points
}

func (p pointTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	p.p.sent.Add(1)
	resp, err := p.base.RoundTrip(r)
	p.p.reach("request " + r.URL.Path)
	return resp, err
}

func (p *points) edit(c *Config) {
	client := *c.Client
	if client.Transport == nil {
		client.Transport = http.DefaultTransport
	}
	client.Transport = pointTransport{base: client.Transport, p: p}
	c.Client = &client
	token, detect, chip, now := c.SetupToken, c.Detect, c.Chip, c.Now
	c.SetupToken = func(ctx context.Context) (string, http.RoundTripper) {
		defer p.reach("setup token")
		return token(ctx)
	}
	c.Detect = func(dir string) disk.Report { p.reach("disks"); return detect(dir) }
	c.Chip = func() bool { p.reach("chip"); return chip() }
	c.Now = func() time.Time { p.reach("clock"); return now() }
}

func (p *points) watch(t *testing.T, b *box) {
	p.b = b
	b.home.mu.Lock()
	// An intent's answer: the action holds the shell and waits for it.
	b.home.answering = func(op string, _ map[string]any) {
		p.sent.Add(1)
		p.reach("intent " + op)
	}
	b.home.mu.Unlock()
	released := b.shell.mu.releasing
	b.shell.mu.releasing = func() {
		released()
		if b.shell.mu.by != nil {
			p.reach("release")
		}
	}
	load, open := loadRecord, openKey
	t.Cleanup(func() { loadRecord, openKey = load, open })
	loadRecord = func(path string) (*holder.Record, error) {
		defer p.reach("record read")
		return load(path)
	}
	openKey = func(r *holder.Record, secret []byte) (*holder.Key, error) {
		defer p.reach("key opened")
		return open(r, secret)
	}
}

// What kind each request is. A page shows only what the shell knows and
// never waits; an action is bounded and cut by a lock; the Lock waits for
// the shell alone.
type kind int

const (
	anAction kind = iota
	aPage
	theLock
)

type scene struct {
	b      *box
	home   *fakeHome
	fields url.Values
	query  string
}

type handlerCase struct {
	route string // METHOD path
	name  string
	kind  kind
	made  func(t *testing.T, edit func(*Config)) scene
}

func aBox(t *testing.T, edit func(*Config)) (*fakeHome, *box) {
	home := newFakeHome(t)
	return home, newBoxAt(t, home, t.TempDir(), home.accounts.URL(), edit)
}

func withKey(t *testing.T, edit func(*Config)) (*fakeHome, *box, string) {
	home, b := aBox(t, edit)
	p := b.shown()
	b.post("/make", url.Values{"secret": {p}, "again": {p}})
	return home, b, p
}

func opened(t *testing.T, edit func(*Config)) (*fakeHome, *box, string) {
	home, b := aBox(t, edit)
	return home, b, setUpAndOpen(t, home, b)
}

func certifiedLocked(t *testing.T, edit func(*Config)) (*fakeHome, *box, string) {
	home, b, p := opened(t, edit)
	b.shell.Lock("")
	return home, b, p
}

func confirmDrawn(t *testing.T, edit func(*Config), draw bool) (*fakeHome, *box, string) {
	home, b, p := opened(t, edit)
	home.mu.Lock()
	home.pending["cnr_1"] = map[string]any{"operation": "vault.create", "preview": map[string]any{"resource": "github"}}
	home.mu.Unlock()
	if draw {
		b.do(http.MethodGet, "/confirm?ref=cnr_1", "", nil)
	}
	return home, b, p
}

func passkeyDrawn(t *testing.T, edit func(*Config), draw bool) (*fakeHome, *box, string, account.Key) {
	home, b, p := opened(t, edit)
	key := newPasskey(t)
	home.mu.Lock()
	home.waiting["pkw_1"] = waitingPasskey("pkw_1", key)
	home.mu.Unlock()
	if draw {
		b.do(http.MethodGet, "/passkey?ref=pkw_1", "", nil)
	}
	return home, b, p, key
}

func handlerCases() []handlerCase {
	return []handlerCase{
		{"GET /", "a screen's", aPage, func(t *testing.T, e func(*Config)) scene {
			home, b := aBox(t, e)
			b.srv.Reachable = func() error { return nil }
			b.srv.reading = true
			return scene{b: b, home: home}
		}},
		{"GET /", "the app's, reading the terms", aPage, func(t *testing.T, e func(*Config)) scene {
			home, b := aBox(t, e)
			home.accounts.Policy = &account.Policy{Version: "2026-10", URL: "https://cyfr.example/terms"}
			return scene{b: b, home: home}
		}},
		{"GET /lock", "", theLock, func(t *testing.T, e func(*Config)) scene {
			home, b, _ := opened(t, e)
			return scene{b: b, home: home}
		}},
		{"POST /lock", "", theLock, func(t *testing.T, e func(*Config)) scene {
			home, b, _ := opened(t, e)
			return scene{b: b, home: home}
		}},
		{"GET /confirm", "", anAction, func(t *testing.T, e func(*Config)) scene {
			home, b, _ := confirmDrawn(t, e, false)
			return scene{b: b, home: home, query: "?ref=cnr_1"}
		}},
		{"GET /confirm", "drawn again, gone", anAction, func(t *testing.T, e func(*Config)) scene {
			home, b, _ := confirmDrawn(t, e, true)
			return scene{b: b, home: home, query: "?ref=cnr_none"}
		}},
		{"GET /passkey", "", anAction, func(t *testing.T, e func(*Config)) scene {
			home, b, _, _ := passkeyDrawn(t, e, false)
			return scene{b: b, home: home, query: "?ref=pkw_1"}
		}},
		{"GET /passkey", "drawn again, gone", anAction, func(t *testing.T, e func(*Config)) scene {
			home, b, _, _ := passkeyDrawn(t, e, true)
			home.mu.Lock()
			clear(home.waiting)
			home.mu.Unlock()
			return scene{b: b, home: home, query: "?ref=pkw_1"}
		}},
		{"POST /passphrase", "", anAction, func(t *testing.T, e func(*Config)) scene {
			home, b := aBox(t, e)
			return scene{b: b, home: home}
		}},
		{"POST /make", "", anAction, func(t *testing.T, e func(*Config)) scene {
			home, b := aBox(t, e)
			p := b.shown()
			return scene{b: b, home: home, fields: url.Values{"secret": {p}, "again": {p}}}
		}},
		{"POST /setup", "", anAction, func(t *testing.T, e func(*Config)) scene {
			home, b := aBox(t, e)
			p := b.shown()
			return scene{b: b, home: home, fields: url.Values{"name": {"alice"}, "secret": {p}, "again": {p}}}
		}},
		{"POST /create", "", anAction, func(t *testing.T, e func(*Config)) scene {
			home, b, p := withKey(t, e)
			return scene{b: b, home: home, fields: url.Values{"name": {"alice"}, "secret": {p}}}
		}},
		{"POST /enroll", "", anAction, func(t *testing.T, e func(*Config)) scene {
			home, b, _ := withKey(t, e)
			identifier, dev, _ := home.account(t, "mira")
			home.approve(t, identifier, dev, b.shell.rec.PublicKey)
			return scene{b: b, home: home, fields: url.Values{"name": {"mira"}}}
		}},
		{"POST /saved", "", anAction, func(t *testing.T, e func(*Config)) scene {
			home, b := aBox(t, e)
			b.setUp("alice")
			return scene{b: b, home: home}
		}},
		{"POST /saved", "the name taken", anAction, func(t *testing.T, e func(*Config)) scene {
			home, b := aBox(t, e)
			b.setUp("alice")
			home.accounts.Hold("alice", "per_"+strings.Repeat("0", 64))
			return scene{b: b, home: home}
		}},
		{"POST /saved", "the terms changed", anAction, func(t *testing.T, e func(*Config)) scene {
			home, b := aBox(t, e)
			home.accounts.Policy = &account.Policy{Version: "2026-10", URL: "https://cyfr.example/terms"}
			b.page()
			p := b.shown()
			b.post("/setup", url.Values{"name": {"alice"}, "secret": {p}, "again": {p}, "accept": {"yes"}})
			home.accounts.Policy = &account.Policy{Version: "2026-11", URL: "https://cyfr.example/terms"}
			return scene{b: b, home: home}
		}},
		{"POST /saved", "another began one first", anAction, func(t *testing.T, e func(*Config)) scene {
			home, b := aBox(t, e)
			b.setUp("alice")
			other := b.shell.making.attempt
			other.Identifier = "per_" + strings.Repeat("7", 64)
			if err := createJSON(b.shell.attemptPath(), other); err != nil {
				t.Fatal(err)
			}
			return scene{b: b, home: home}
		}},
		{"POST /saved", "listed elsewhere meanwhile", anAction, func(t *testing.T, e func(*Config)) scene {
			home, b := aBox(t, e)
			b.setUp("alice")
			rec, err := holder.Load(b.record)
			if err != nil {
				t.Fatal(err)
			}
			rec.Identifier = "per_" + strings.Repeat("7", 64)
			if err := rec.Save(b.record); err != nil {
				t.Fatal(err)
			}
			return scene{b: b, home: home}
		}},
		{"POST /saved", "the hello refused", anAction, func(t *testing.T, e func(*Config)) scene {
			home, b := aBox(t, e)
			b.setUp("alice")
			home.mu.Lock()
			home.setupUsed = true
			home.mu.Unlock()
			return scene{b: b, home: home}
		}},
		{"POST /saved", "the changed terms accepted", anAction, func(t *testing.T, e func(*Config)) scene {
			home, b := aBox(t, e)
			home.accounts.Policy = &account.Policy{Version: "2026-10", URL: "https://cyfr.example/terms"}
			b.page()
			p := b.shown()
			b.post("/setup", url.Values{"name": {"alice"}, "secret": {p}, "again": {p}, "accept": {"yes"}})
			home.accounts.Policy = &account.Policy{Version: "2026-11", URL: "https://cyfr.example/terms"}
			b.post("/saved", nil)
			return scene{b: b, home: home, fields: url.Values{"accept": {"yes"}}}
		}},
		{"POST /resume", "", anAction, func(t *testing.T, e func(*Config)) scene {
			home := newFakeHome(t)
			dir := t.TempDir()
			first := newBox(t, home, dir)
			first.setUp("alice")
			code := first.recovery()
			home.accounts.Down = true
			first.post("/saved", nil)
			home.accounts.Down = false
			b := newBoxAt(t, home, dir, home.accounts.URL(), e)
			return scene{b: b, home: home, fields: url.Values{"code": {code}}}
		}},
		{"POST /name", "", anAction, func(t *testing.T, e func(*Config)) scene {
			home, b := aBox(t, e)
			b.setUp("alice")
			home.accounts.Hold("alice", "per_"+strings.Repeat("0", 64))
			b.post("/saved", nil)
			return scene{b: b, home: home, fields: url.Values{"name": {"alice2"}}}
		}},
		{"POST /unlock", "the first hello", anAction, func(t *testing.T, e func(*Config)) scene {
			home := newFakeHome(t)
			b, p := neverConnected(t, home, e)
			return scene{b: b, home: home, fields: url.Values{"secret": {p}}}
		}},
		{"POST /unlock", "certified", anAction, func(t *testing.T, e func(*Config)) scene {
			home, b, p := certifiedLocked(t, e)
			return scene{b: b, home: home, fields: url.Values{"secret": {p}}}
		}},
		{"POST /unlock", "the standing ended", anAction, func(t *testing.T, e func(*Config)) scene {
			home, b, p := certifiedLocked(t, e)
			home.revoke()
			return scene{b: b, home: home, fields: url.Values{"secret": {p}}}
		}},
		{"POST /unlock", "a certificate of another address", anAction, func(t *testing.T, e func(*Config)) scene {
			home, b, p := certifiedLocked(t, e)
			var cert map[string]any
			if err := json.Unmarshal(b.shell.here.Certificate, &cert); err != nil {
				t.Fatal(err)
			}
			cert["audience"] = "https://cyfr-old.example"
			raw, err := json.Marshal(cert)
			if err != nil {
				t.Fatal(err)
			}
			b.shell.here.Certificate = raw
			return scene{b: b, home: home, fields: url.Values{"secret": {p}}}
		}},
		{"POST /unlock", "the key no longer listed", anAction, func(t *testing.T, e func(*Config)) scene {
			home := newFakeHome(t)
			identifier, dev, _ := home.account(t, "mira")
			b := newBoxAt(t, home, t.TempDir(), home.accounts.URL(), e)
			p := b.shown()
			b.post("/make", url.Values{"secret": {p}, "again": {p}})
			pub := b.shell.rec.PublicKey
			home.approve(t, identifier, dev, pub)
			b.post("/enroll", url.Values{"name": {"mira"}})
			removeKey(t, home, identifier, dev, pub)
			return scene{b: b, home: home, fields: url.Values{"secret": {p}}}
		}},
		{"POST /unlock", "with a key held since setup", anAction, func(t *testing.T, e func(*Config)) scene {
			home, b := aBox(t, e)
			p := b.setUp("alice")
			rec, err := holder.Load(b.record)
			if err != nil {
				t.Fatal(err)
			}
			rec.Identifier, rec.Directory = "per_"+strings.Repeat("7", 64), home.accounts.URL()
			if err := rec.Save(b.record); err != nil {
				t.Fatal(err)
			}
			b.post("/saved", nil)
			if b.shell.key == nil {
				t.Fatal("no key is held")
			}
			b.shell.mu.Lock()
			b.shell.notice = ""
			b.shell.mu.Unlock()
			return scene{b: b, home: home, fields: url.Values{"secret": {p}}}
		}},
		{"POST /open", "", anAction, func(t *testing.T, e func(*Config)) scene {
			home, b, _ := opened(t, e)
			return scene{b: b, home: home}
		}},
		{"POST /open", "without the proof", anAction, func(t *testing.T, e func(*Config)) scene {
			home, b, _ := opened(t, e)
			b.proof = ""
			return scene{b: b, home: home}
		}},
		{"POST /recovery", "", anAction, func(t *testing.T, e func(*Config)) scene {
			home, b := aBox(t, e)
			b.setUp("alice")
			return scene{b: b, home: home}
		}},
		{"POST /confirm/decide", "confirm", anAction, func(t *testing.T, e func(*Config)) scene {
			home, b, p := confirmDrawn(t, e, true)
			return scene{b: b, home: home, fields: url.Values{"ref": {"cnr_1"}, "decision": {"confirm"}, "secret": {p}}}
		}},
		{"POST /confirm/decide", "confirm, the change gone", anAction, func(t *testing.T, e func(*Config)) scene {
			home, b, p := confirmDrawn(t, e, true)
			home.mu.Lock()
			clear(home.pending)
			home.mu.Unlock()
			return scene{b: b, home: home, fields: url.Values{"ref": {"cnr_1"}, "decision": {"confirm"}, "secret": {p}}}
		}},
		{"POST /confirm/decide", "cancel", anAction, func(t *testing.T, e func(*Config)) scene {
			home, b, _ := confirmDrawn(t, e, true)
			return scene{b: b, home: home, fields: url.Values{"ref": {"cnr_1"}, "decision": {"cancel"}}}
		}},
		{"POST /passkey/decide", "approve", anAction, func(t *testing.T, e func(*Config)) scene {
			home, b, p, key := passkeyDrawn(t, e, true)
			return scene{b: b, home: home, fields: url.Values{"ref": {"pkw_1"}, "key": {keyDigest(key)}, "decision": {"approve"}, "secret": {p}}}
		}},
		{"POST /passkey/decide", "approve, the request gone", anAction, func(t *testing.T, e func(*Config)) scene {
			home, b, p, key := passkeyDrawn(t, e, true)
			home.mu.Lock()
			clear(home.waiting)
			home.mu.Unlock()
			return scene{b: b, home: home, fields: url.Values{"ref": {"pkw_1"}, "key": {keyDigest(key)}, "decision": {"approve"}, "secret": {p}}}
		}},
		{"POST /passkey/decide", "cancel", anAction, func(t *testing.T, e func(*Config)) scene {
			home, b, _, key := passkeyDrawn(t, e, true)
			return scene{b: b, home: home, fields: url.Values{"ref": {"pkw_1"}, "key": {keyDigest(key)}, "decision": {"cancel"}}}
		}},
	}
}

func (c handlerCase) title() string {
	return strings.TrimSpace(strings.NewReplacer("/", "_", " ", "").Replace(c.route) + " " + c.name)
}

func (c handlerCase) request(ctx context.Context, s scene, reading func()) *http.Request {
	method, path, _ := strings.Cut(c.route, " ")
	if method == http.MethodGet {
		return httptest.NewRequest(method, "http://"+Listen+path+s.query, nil).WithContext(ctx)
	}
	fields := url.Values{}
	maps.Copy(fields, s.fields)
	fields.Set("proof", s.b.proof)
	var body io.Reader = strings.NewReader(fields.Encode())
	if reading != nil {
		body = &readOnce{Reader: body, reading: reading}
	}
	r := httptest.NewRequest(method, "http://"+Listen+path, body).WithContext(ctx)
	r.Header.Set("Origin", Origin)
	r.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	return r
}

// readOnce runs reading as the request's form is first read, which is
// after its action began and before it first waits for the shell.
type readOnce struct {
	io.Reader
	reading func()
}

func (r *readOnce) Read(p []byte) (int, error) {
	if r.reading != nil {
		r.reading()
		r.reading = nil
	}
	return r.Reader.Read(p)
}

// The table holds every handler: one added without its row fails here.
func TestGate_TheTableHoldsEveryHandler(t *testing.T) {
	var want, have []string
	for path := range actions {
		want = append(want, "POST "+path)
	}
	for path := range reads {
		want = append(want, "GET "+path)
	}
	for _, c := range handlerCases() {
		have = append(have, c.route)
	}
	slices.Sort(want)
	slices.Sort(have)
	if have = slices.Compact(have); !slices.Equal(want, have) {
		t.Fatalf("the server handles %v and the table proves %v", want, have)
	}
}

// Rule a, at every point of every handler: from the moment its generation
// ends, an action changes nothing, however well its work goes on to
// succeed, and is answered as cut short.
func TestGate_AnEndedGenerationChangesNothing(t *testing.T) {
	for _, c := range handlerCases() {
		if c.kind == theLock {
			continue
		}
		t.Run(c.title(), func(t *testing.T) {
			run := func(t *testing.T, at int) int {
				p := &points{at: at}
				s := c.made(t, p.edit)
				p.watch(t, s.b)
				makeDeaf(s.b.shell)
				var then, where string
				var sent int32
				var locked func()
				if at > 0 {
					p.hit = func(point string) {
						where = point
						locked, _ = s.b.shell.end(nil)
						then = wholeState(t, s.b)
						sent = p.sent.Load()
					}
				}
				r := c.request(context.Background(), s, nil)
				w := httptest.NewRecorder()
				p.on = true
				s.b.srv.ServeHTTP(w, r)
				p.on = false
				if locked == nil {
					return p.seen
				}
				defer locked()
				s.b.shell.mu.Lock()
				now := wholeState(t, s.b)
				s.b.shell.mu.Unlock()
				if now != then {
					t.Errorf("ended at point %d (%s), it changed the shell:\n%s", at, where, stateDiff(then, now))
				}
				if where == "key opened" && p.sent.Load() != sent {
					t.Errorf("ended as the key was opened, it went on to sign and send")
				}
				// http.Redirect gives a GET a link to the same place as its body.
				page := strings.TrimSpace(w.Body.String())
				if c.kind == anAction && (w.Code != http.StatusSeeOther || w.Header().Get("Location") != "/" || (page != "" && page != `<a href="/">See Other</a>.`)) {
					t.Errorf("ended at point %d (%s), it answered %d %q %.120q", at, where, w.Code, w.Header().Get("Location"), w.Body.String())
				}
				return p.seen
			}
			var n int
			t.Run("whole", func(t *testing.T) { n = run(t, 0) })
			if n == 0 {
				t.Fatal("the handler passed no point")
			}
			for at := 1; at <= n; at++ {
				t.Run(fmt.Sprint(at), func(t *testing.T) { run(t, at) })
			}
		})
	}
}

// Rule a, where the request ended first: an action its client gave up, its
// deadline ended or nobody ended changes nothing after a lock, and that
// lock's sentence stands.
func TestGate_WhatEndedTheRequestDoesNotMatter(t *testing.T) {
	for _, c := range handlerCases() {
		method, _, _ := strings.Cut(c.route, " ")
		if c.kind != anAction || method != http.MethodPost {
			continue // a GET has no form: TestGate_EveryEntry is theirs
		}
		for _, first := range []string{"the client", "the deadline", "nobody"} {
			t.Run(c.title()+", "+first, func(t *testing.T) {
				s := c.made(t, func(*Config) {})
				ctx, cancel := context.WithCancel(context.Background())
				defer cancel()
				parent, over := context.Context(ctx), newExpiring()
				if first == "the deadline" {
					parent = over
				}
				var then string
				r := c.request(parent, s, func() {
					switch first {
					case "the client":
						cancel()
					case "the deadline":
						over.expire()
					}
					s.b.shell.Lock(suspendedHere)
					s.b.shell.mu.Lock()
					then = wholeState(t, s.b)
					s.b.shell.mu.Unlock()
				})
				w := httptest.NewRecorder()
				s.b.srv.ServeHTTP(w, r)
				s.b.shell.mu.Lock()
				now := wholeState(t, s.b)
				s.b.shell.mu.Unlock()
				if now != then {
					t.Fatalf("it changed the shell after the lock returned:\n%s", stateDiff(then, now))
				}
				if w.Code != http.StatusSeeOther || w.Header().Get("Location") != "/" || w.Body.Len() != 0 {
					t.Fatalf("it answered %d %q", w.Code, w.Header().Get("Location"))
				}
			})
		}
	}
}

// Rule b, at every handler: with the shell held, a request that waits for
// it returns as its own time runs out and as its generation ends, and the
// Lock alone waits, its generation already ended. Only the time that ran
// out waiting is told as a busy device.
func TestGate_NoHandlerOutwaitsItsRequest(t *testing.T) {
	for _, c := range handlerCases() {
		t.Run(c.title(), func(t *testing.T) {
			var s scene
			if c.kind != theLock {
				// Both rows leave the shell as they found it, or fail saying
				// so, so they share it.
				s = c.made(t, func(*Config) {})
			}
			for _, by := range []string{"deadline", "generation"} {
				t.Run(by, func(t *testing.T) {
					s := s
					if c.kind == theLock {
						s = c.made(t, func(*Config) {})
					}
					sh := s.b.shell
					waiting := waiters(sh)
					sh.mu.Lock()
					held := true
					defer func() {
						if held {
							sh.mu.Unlock()
						}
					}()
					then := wholeState(t, s.b)
					sh.genMu.Lock()
					began := sh.gen
					sh.genMu.Unlock()
					over := newExpiring()
					answered := make(chan *httptest.ResponseRecorder, 1)
					go func() {
						w := httptest.NewRecorder()
						s.b.srv.ServeHTTP(w, c.request(over, s, nil))
						answered <- w
					}()
					if c.kind == theLock {
						becomesTrue(t, "the lock ends the generation first", func() bool { return !began.live() })
						held = false
						sh.mu.Unlock()
						returns(t, "the lock", func() { <-answered })
						return
					}
					var w *httptest.ResponseRecorder
					if c.kind == anAction {
						waits(t, "the request", waiting)
					} else {
						// Of the pages only the app's waits, to keep the terms it read.
						select {
						case <-waiting:
						case w = <-answered:
						case <-time.After(10 * time.Second):
							t.Fatal("the page neither answered nor waited")
						}
					}
					if w == nil {
						if by == "deadline" {
							over.expire()
						} else {
							locked, _ := sh.end(nil)
							defer locked()
						}
						returns(t, "the request", func() { w = <-answered })
					}
					if now := wholeState(t, s.b); now != then {
						t.Fatalf("it changed the shell it never took:\n%s", stateDiff(then, now))
					}
					if c.kind != anAction {
						return
					}
					if by == "generation" && w.Code != http.StatusSeeOther {
						t.Fatalf("a lock's end was answered %d", w.Code)
					}
					if by == "deadline" && !strings.Contains(body(w), stillBusy) {
						t.Fatalf("a wait that outlasted its time was not told so: %d\n%s", w.Code, body(w))
					}
				})
			}
		})
	}
}

// Only a wait that outlasted an action's time, its work not begun, is told
// as a busy device.
func TestGate_OnlyTheWaitForTheShellSaysBusy(t *testing.T) {
	for _, c := range []struct {
		name   string
		before func(s *Shell, ctx context.Context)
		held   bool
		ends   string
		lock   bool
		busy   bool
	}{
		{name: "waiting to begin", held: true, ends: "deadline", busy: true},
		{name: "waiting for its work, begun", before: func(s *Shell, ctx context.Context) { s.Begin(ctx) }, held: true, ends: "deadline", busy: true},
		{name: "waiting again, its work under way", before: func(s *Shell, ctx context.Context) { s.CheckListed(ctx) }, held: true, ends: "deadline"},
		{name: "waiting as the person left", held: true, ends: "client"},
		{name: "waiting to begin, then a lock", held: true, ends: "deadline", lock: true},
		{name: "its time over before it asked a held shell", held: true, ends: "before"},
		{name: "its time over before it asked a free shell", ends: "before"},
		{name: "its time over, its work under way, the shell held", before: func(s *Shell, ctx context.Context) { s.CheckListed(ctx) }, held: true, ends: "before"},
	} {
		t.Run(c.name, func(t *testing.T) {
			_, b, _ := certifiedLocked(t, func(*Config) {})
			s := b.shell
			waiting := waiters(s)
			over := newExpiring()
			parent, cancel := context.WithCancel(over)
			defer cancel()
			ctx, done := s.act(parent)
			defer done()
			if c.before != nil {
				c.before(s, ctx)
			}
			if c.held {
				s.mu.Lock()
			}
			if c.ends == "before" {
				over.expire()
				<-ctx.Done()
			}
			var ok bool
			asked := make(chan struct{})
			go func() {
				defer close(asked)
				_, ok = s.pageView(ctx, nil)
			}()
			if c.ends != "before" {
				waits(t, "the action", waiting)
				if c.ends == "deadline" {
					over.expire()
				} else {
					cancel()
				}
			}
			returns(t, "the action", func() { <-asked })
			if ok {
				t.Fatal("it took the shell")
			}
			if c.held {
				s.mu.Unlock()
			}
			if c.ends == "deadline" {
				if _, ok := s.pageView(ctx, nil); ok {
					t.Fatal("an action whose wait ran out went on")
				}
			}
			if c.lock {
				s.Lock(suspendedHere)
			}
			w := httptest.NewRecorder()
			b.srv.gaveUp(ctx, w, httptest.NewRequest(http.MethodPost, Origin+"/unlock", nil))
			if said := strings.Contains(body(w), stillBusy); said != c.busy {
				t.Fatalf("told as a busy device: %v", said)
			}
		})
	}
}

// entries are the shell's methods that take it for an action.
func entries() map[string]func(b *box, ctx context.Context, p string) {
	secret := func(p string) []byte { return []byte(strings.Clone(p)) }
	return map[string]func(b *box, ctx context.Context, p string){
		"Begin":          func(b *box, ctx context.Context, _ string) { b.shell.Begin(ctx) },
		"CheckListed":    func(b *box, ctx context.Context, _ string) { b.shell.CheckListed(ctx) },
		"Create":         func(b *box, ctx context.Context, _ string) { b.shell.Create(ctx, "bob", "") },
		"Decide":         func(b *box, ctx context.Context, p string) { b.shell.Decide(ctx, "cnr_1", true, secret(p)) },
		"DecidePasskey":  func(b *box, ctx context.Context, p string) { b.shell.DecidePasskey(ctx, "pkw_1", "x", true, secret(p)) },
		"Draw":           func(b *box, ctx context.Context, _ string) { b.shell.Draw(ctx, "cnr_1") },
		"DrawPasskey":    func(b *box, ctx context.Context, _ string) { b.shell.DrawPasskey(ctx, "pkw_1") },
		"Rename":         func(b *box, ctx context.Context, _ string) { b.shell.Rename(ctx, "bob") },
		"Resume":         func(b *box, ctx context.Context, _ string) { b.shell.Resume(ctx, "CYFR-0000") },
		"Terms":          func(b *box, ctx context.Context, _ string) { _, _ = b.shell.Terms(ctx) },
		"Ticket":         func(b *box, ctx context.Context, _ string) { _, _ = b.shell.Ticket(ctx, []byte(b.proof)) },
		"asPage":         func(b *box, ctx context.Context, _ string) { b.shell.asPage(ctx, nil, func(context.Context) {}) },
		"confirmView":    func(b *box, ctx context.Context, _ string) { b.shell.confirmView(ctx, "cnr_1") },
		"createOpened":   func(b *box, ctx context.Context, p string) { b.shell.createOpened(ctx, "bob", "", secret(p)) },
		"drawPassphrase": func(b *box, ctx context.Context, _ string) { b.shell.drawPassphrase(ctx) },
		"enrollByPage":   func(b *box, ctx context.Context, _ string) { b.shell.enrollByPage(ctx, "bob", time.Second, nil) },
		"makeKey":        func(b *box, ctx context.Context, p string) { b.shell.makeKey(ctx, secret(p), secret(p)) },
		"pageView":       func(b *box, ctx context.Context, _ string) { b.shell.pageView(ctx, nil) },
		"passkeyView":    func(b *box, ctx context.Context, _ string) { b.shell.passkeyView(ctx, "pkw_1") },
		"readTerms":      func(b *box, ctx context.Context, _ string) { b.shell.readTerms(ctx) },
		"resumeByPage":   func(b *box, ctx context.Context, _ string) { b.shell.resumeByPage(ctx, "CYFR-0000") },
		"setup":          func(b *box, ctx context.Context, p string) { b.shell.setup(ctx, "bob", "", secret(p), secret(p)) },
		"tell":           func(b *box, ctx context.Context, _ string) { b.shell.tell(ctx, "told") },
		"unlock":         func(b *box, ctx context.Context, p string) { b.shell.unlock(ctx, secret(p)) },
	}
}

// Every taking of the shell is on an exact roster: an action's by take,
// the two that run on past one bound to a generation, and the two locks.
func TestGate_EveryTakingIsOnTheRoster(t *testing.T) {
	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	found := map[string][]string{}
	for _, file := range files {
		if strings.HasSuffix(file, "_test.go") {
			continue
		}
		tree, err := parser.ParseFile(token.NewFileSet(), file, nil, 0)
		if err != nil {
			t.Fatal(err)
		}
		for _, d := range tree.Decls {
			name, recv, node := "", "", ast.Node(d)
			if f, ok := d.(*ast.FuncDecl); ok {
				name = f.Name.Name
				if f.Recv != nil {
					if star, ok := f.Recv.List[0].Type.(*ast.StarExpr); ok {
						recv = fmt.Sprint(star.X)
					}
				}
			} else {
				name = file + "'s declarations"
			}
			if recv == "shellLock" || recv == "Selection" || recv == "Channel" {
				continue
			}
			ast.Inspect(node, func(n ast.Node) bool {
				sel, ok := n.(*ast.SelectorExpr)
				if !ok {
					return true
				}
				inner, onField := sel.X.(*ast.SelectorExpr)
				switch {
				case sel.Sel.Name == "take":
					found["take"] = append(found["take"], name)
				case onField && inner.Sel.Name == "mu" && (recv == "Shell" || recv == "Server" || recv == ""):
					if sel.Sel.Name == "Lock" || sel.Sel.Name == "lockFor" || sel.Sel.Name == "held" {
						found[sel.Sel.Name] = append(found[sel.Sel.Name], name)
					}
				}
				return true
			})
		}
	}
	for k := range found {
		slices.Sort(found[k])
		found[k] = slices.Compact(found[k])
	}
	actions := slices.Sorted(maps.Keys(entries()))
	// View is for a caller that begins no action: it begins one itself.
	actions = append(actions, "View")
	slices.Sort(actions)
	for how, want := range map[string][]string{
		"take":    actions,
		"Lock":    {"Lock", "watch"},
		"lockFor": {"renewed", "scheduleRenewal", "take"},
		"held":    {"New"},
	} {
		if !slices.Equal(found[how], want) {
			t.Errorf("the shell is taken by %s in %v, and the roster says %v", how, found[how], want)
		}
	}
}

// Both rules at every entry of the shell: begun before a lock, whatever
// cancelled it first, it changes nothing after that lock returns; and
// waiting on a held shell it returns at its deadline and at a lock.
func TestGate_EveryEntry(t *testing.T) {
	// The rows on a held shell leave it as they found it, or fail saying
	// so, so they share one.
	_, held, passphrase := opened(t, func(*Config) {})
	held.shell.mu.Lock()
	held.shell.configured = false
	held.shell.mu.Unlock()
	for name, call := range entries() {
		for _, first := range []string{"the client", "the deadline", "nobody"} {
			t.Run(name+" after a lock, "+first+" first", func(t *testing.T) {
				_, b, p := opened(t, func(*Config) {})
				parent, cancel := context.WithCancel(context.Background())
				if first == "the deadline" {
					parent, cancel = context.WithDeadline(context.Background(), time.Now().Add(-time.Second))
				}
				defer cancel()
				ctx, done := b.shell.act(parent)
				defer done()
				if first == "the client" {
					cancel()
				}
				b.shell.Lock(suspendedHere)
				b.shell.mu.Lock()
				b.shell.configured = false
				then := wholeState(t, b)
				b.shell.mu.Unlock()
				call(b, ctx, p)
				b.shell.mu.Lock()
				now := wholeState(t, b)
				b.shell.mu.Unlock()
				if now != then {
					t.Fatalf("it changed the shell after the lock returned:\n%s", stateDiff(then, now))
				}
			})
		}
		for _, by := range []string{"deadline", "generation"} {
			t.Run(name+" on a held shell, "+by, func(t *testing.T) {
				waiting := waiters(held.shell)
				held.shell.mu.Lock()
				defer held.shell.mu.Unlock()
				then := wholeState(t, held)
				over := newExpiring()
				ctx, done := held.shell.act(over)
				defer done()
				returned := make(chan struct{})
				go func() {
					defer close(returned)
					call(held, ctx, passphrase)
				}()
				waits(t, name, waiting)
				if by == "deadline" {
					over.expire()
				} else {
					locked, _ := held.shell.end(nil)
					defer locked()
				}
				returns(t, name, func() { <-returned })
				if now := wholeState(t, held); now != then {
					t.Fatalf("it changed a shell it never took:\n%s", stateDiff(then, now))
				}
			})
		}
	}
}

// overUnheard is a time that ran out just as the shell was given up: the
// wait hears the shell first, and Err alone says so.
type overUnheard struct {
	context.Context
	over atomic.Bool
}

func (o *overUnheard) Err() error {
	if o.over.Load() {
		return context.DeadlineExceeded
	}
	return nil
}

func TestGate_AShellGivenUpAsTheTimeRanOutWasWaitedForTooLong(t *testing.T) {
	l := &shellLock{held: make(chan struct{}, 1), releasing: func() {}}
	l.Lock()
	ctx := &overUnheard{Context: context.Background()}
	l.waiting = func() {
		ctx.over.Store(true)
		<-l.held
	}
	if err := l.lockFor(ctx, newGeneration(), true); !errors.Is(err, errWaitedOut) || len(l.held) != 0 {
		t.Fatalf("it was answered %v, holding %d", err, len(l.held))
	}
}

// An action that could not take the shell asks for no ticket and is not
// told that the device locked.
func TestGate_AShellNotTakenIsNoLock(t *testing.T) {
	_, b, _ := opened(t, func(*Config) {})
	b.shell.mu.Lock()
	defer b.shell.mu.Unlock()
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := b.shell.Ticket(ctx, []byte(b.proof)); !errors.Is(err, errNotTaken) {
		t.Fatalf("it was answered %v", err)
	}
}

// A ticket the CYFR answered after the generation ended is handed to no
// one.
func TestGate_AnEndedGenerationGetsNoTicket(t *testing.T) {
	home, b, _ := opened(t, func(*Config) {})
	makeDeaf(b.shell)
	var locked func()
	home.mu.Lock()
	home.answering = func(op string, args map[string]any) {
		if _, spent := args["proof"]; spent && op == "session.unlock" {
			locked, _ = b.shell.end(nil)
		}
	}
	home.mu.Unlock()
	ticket, err := b.shell.Ticket(context.Background(), []byte(b.proof))
	if locked == nil {
		t.Fatal("no session was spent")
	}
	defer locked()
	if ticket != "" || err == nil {
		t.Fatalf("it got %q", ticket)
	}
}

// connect is no entry, and opens nothing for a generation that ended.
func TestGate_ConnectOpensNothingForAnEndedGeneration(t *testing.T) {
	home := newFakeHome(t)
	b, p := neverConnected(t, home)
	makeDeaf(b.shell)
	ctx, give, ok := b.shell.take(context.Background())
	if !ok {
		t.Fatal("the shell was not taken")
	}
	defer give()
	key, err := b.shell.rec.Open([]byte(p))
	if err != nil {
		t.Fatal(err)
	}
	defer key.Erase()
	locked, _ := b.shell.end(nil)
	defer locked()
	if err := b.shell.connect(ctx, key); err == nil || len(home.hellosSeen()) != 0 || b.shell.open.Load() {
		t.Fatalf("connect went on: %v", err)
	}
}

// A certificate that arrives for a channel of an ended generation is not
// kept, whether it finds the shell held or free, and waits for neither.
func TestGate_ARenewalOfAnEndedGenerationIsNotKept(t *testing.T) {
	for _, row := range []string{"waiting for a held shell", "finding a free shell"} {
		t.Run(row, func(t *testing.T) {
			_, b, _ := opened(t, func(*Config) {})
			s := b.shell
			waiting := waiters(s)
			var locked func()
			var done <-chan struct{}
			if row == "waiting for a held shell" {
				s.mu.Lock()
				defer s.mu.Unlock()
				done = s.renewed(s.gen, json.RawMessage(`{"kept":"no"}`))
				waits(t, "the renewal", waiting)
				locked, _ = s.end(nil)
			} else {
				makeDeaf(s)
				began := s.gen
				locked, _ = s.end(nil)
				done = s.renewed(began, json.RawMessage(`{"kept":"no"}`))
			}
			defer locked()
			returns(t, "the renewal", func() { <-done })
			if strings.Contains(string(s.here.Certificate), "kept") {
				t.Fatal("it was kept")
			}
		})
	}
}
