// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package shell

import (
	"context"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"
)

// expiring is a request's time, which runs out when the test says: after
// the event it is to outlast, never by a clock racing that event.
type expiring struct {
	context.Context
	over chan struct{}
}

func newExpiring() *expiring {
	return &expiring{Context: context.Background(), over: make(chan struct{})}
}

func (e *expiring) expire() { close(e.over) }

func (e *expiring) Done() <-chan struct{} { return e.over }

func (e *expiring) Err() error {
	select {
	case <-e.over:
		return context.DeadlineExceeded
	default:
		return nil
	}
}

func (e *expiring) Deadline() (time.Time, bool) { return time.Time{}, false }

// A deadline that ends once the action took the shell is that action's own
// failure, told as it tells it, and never as a busy device.
func TestCause_ADeadlineAfterTheShellWasTakenIsTheActionsOwnFailure(t *testing.T) {
	const deadline = "context deadline exceeded"
	// at is where the action is as its time runs out: an intent's answer,
	// or the first request that is the dial or is none.
	anyRequest := func(r *http.Request) bool { return !theDial(r) }
	type made struct {
		b      *box
		fields url.Values
	}
	confirming := func(draw bool) func(*testing.T, *fakeHome, func(*Config)) made {
		return func(t *testing.T, home *fakeHome, e func(*Config)) made {
			b := newBoxAt(t, home, t.TempDir(), home.accounts.URL(), e)
			p := setUpAndOpen(t, home, b)
			home.mu.Lock()
			home.pending["cnr_1"] = map[string]any{"operation": "vault.create", "preview": map[string]any{"resource": "github"}}
			home.mu.Unlock()
			if draw {
				b.do(http.MethodGet, "/confirm?ref=cnr_1", "", nil)
			}
			return made{b, url.Values{"ref": {"cnr_1"}, "decision": {"confirm"}, "secret": {p}}}
		}
	}
	approving := func(draw bool) func(*testing.T, *fakeHome, func(*Config)) made {
		return func(t *testing.T, home *fakeHome, e func(*Config)) made {
			b := newBoxAt(t, home, t.TempDir(), home.accounts.URL(), e)
			p := setUpAndOpen(t, home, b)
			key := newPasskey(t)
			home.mu.Lock()
			home.waiting["pkw_1"] = waitingPasskey("pkw_1", key)
			home.mu.Unlock()
			if draw {
				b.do(http.MethodGet, "/passkey?ref=pkw_1", "", nil)
			}
			return made{b, url.Values{"ref": {"pkw_1"}, "key": {keyDigest(key)}, "decision": {"approve"}, "secret": {p}}}
		}
	}
	locked := func(t *testing.T, home *fakeHome, e func(*Config)) made {
		b := newBoxAt(t, home, t.TempDir(), home.accounts.URL(), e)
		p := setUpAndOpen(t, home, b)
		b.shell.Lock("")
		return made{b, url.Values{"secret": {p}}}
	}
	for _, c := range []struct {
		name, route string
		made        func(*testing.T, *fakeHome, func(*Config)) made
		intent      string
		request     func(*http.Request) bool
		says        []string
		code        int
		handsProof  bool
	}{
		{name: "an unlock at the session's answer", route: "POST /unlock", made: locked,
			intent: "session.unlock", code: http.StatusOK, says: []string{deadline}, handsProof: true},
		{name: "an unlock in the dial", route: "POST /unlock", made: locked,
			request: theDial, code: http.StatusOK, says: []string{"CYFR could not be reached."}, handsProof: true},
		{name: "an unlock reading the account", route: "POST /unlock", made: locked,
			request: anyRequest, code: http.StatusOK, says: []string{"CYFR could not be reached."}, handsProof: true},
		{name: "opening CYFR", route: "POST /open",
			made: func(t *testing.T, home *fakeHome, e func(*Config)) made {
				b := newBoxAt(t, home, t.TempDir(), home.accounts.URL(), e)
				setUpAndOpen(t, home, b)
				return made{b, nil}
			},
			intent: "session.unlock", code: http.StatusSeeOther, says: []string{deadline}},
		{name: "a setup", route: "POST /setup",
			made: func(t *testing.T, home *fakeHome, e func(*Config)) made {
				b := newBoxAt(t, home, t.TempDir(), home.accounts.URL(), e)
				p := b.shown()
				return made{b, url.Values{"name": {"alice"}, "secret": {p}, "again": {p}}}
			},
			request: anyRequest, code: http.StatusSeeOther, says: []string{"The account service could not be reached", deadline}},
		{name: "an account being sent", route: "POST /saved",
			made: func(t *testing.T, home *fakeHome, e func(*Config)) made {
				b := newBoxAt(t, home, t.TempDir(), home.accounts.URL(), e)
				b.setUp("alice")
				return made{b, nil}
			},
			request: anyRequest, code: http.StatusSeeOther, says: []string{"Your account is not finished:"}},
		{name: "an enrollment", route: "POST /enroll",
			made: func(t *testing.T, home *fakeHome, e func(*Config)) made {
				b := newBoxAt(t, home, t.TempDir(), home.accounts.URL(), e)
				p := b.shown()
				b.post("/make", url.Values{"secret": {p}, "again": {p}})
				return made{b, url.Values{"name": {"mira"}}}
			},
			request: anyRequest, code: http.StatusSeeOther, says: []string{"The account service could not be reached", deadline}},
		{name: "drawing a confirmation", route: "GET /confirm?ref=cnr_1", made: confirming(false),
			intent: "confirmation.pending", code: http.StatusOK, says: []string{deadline}},
		{name: "confirming", route: "POST /confirm/decide", made: confirming(true),
			intent: "confirmation.request", code: http.StatusOK, says: []string{"CYFR did not take the confirmation: " + deadline}},
		{name: "drawing a passkey", route: "GET /passkey?ref=pkw_1", made: approving(false),
			intent: "pairing.waiting", code: http.StatusOK, says: []string{`class="notice"`}},
		{name: "approving a passkey", route: "POST /passkey/decide", made: approving(true),
			request: anyRequest, code: http.StatusOK, says: []string{`class="notice"`}},
	} {
		t.Run(c.name, func(t *testing.T) {
			home := newFakeHome(t)
			g := newGate(t)
			only := c.request
			if only == nil {
				only = func(*http.Request) bool { return false }
			}
			m := c.made(t, home, gated(g, only))
			if c.intent != "" {
				home.mu.Lock()
				home.answering = func(op string, _ map[string]any) {
					if op == c.intent {
						_ = g.pass(context.Background())
					}
				}
				home.mu.Unlock()
			}
			g.shut()
			method, path, _ := strings.Cut(c.route, " ")
			fields := url.Values{"proof": {m.b.proof}}
			for k, v := range m.fields {
				fields[k] = v
			}
			over := newExpiring()
			r := httptest.NewRequest(method, "http://"+Listen+path, strings.NewReader(fields.Encode())).WithContext(over)
			if method == http.MethodPost {
				r.Header.Set("Origin", Origin)
				r.Header.Set("Content-Type", "application/x-www-form-urlencoded")
			}
			answered := make(chan *httptest.ResponseRecorder, 1)
			go func() {
				w := httptest.NewRecorder()
				m.b.srv.ServeHTTP(w, r)
				answered <- w
			}()
			g.reached(t)
			over.expire()
			var w *httptest.ResponseRecorder
			returns(t, "the action whose time ran out", func() { w = <-answered })
			g.open()
			page := body(w)
			if w.Code == http.StatusSeeOther {
				page = m.b.page()
			}
			if strings.Contains(page, "busy with what was asked before") {
				t.Fatalf("an action that held the shell was told that others held it:\n%s", page)
			}
			for _, says := range c.says {
				if !strings.Contains(page, says) {
					t.Errorf("it does not say %q, as its own failure does:\n%s", says, page)
				}
			}
			if w.Code != c.code {
				t.Errorf("it answered %d, where its own failure answers %d", w.Code, c.code)
			}
			if handed := proofIn(w) != ""; handed != c.handsProof {
				t.Errorf("it handed a proof: %v", handed)
			}
		})
	}
}
