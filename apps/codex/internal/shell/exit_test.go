// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package shell

import (
	"go/ast"
	"go/parser"
	"go/token"
	"net/http"
	"net/url"
	"slices"
	"strconv"
	"strings"
	"testing"
)

const browserClosed = "Locked because the browser closed."

// exitCase is one state the shell can be in as the screen's browser exits.
// made answers the box, and where an action is in flight what ends once it
// has.
type exitCase struct {
	name string
	page Page
	made func(t *testing.T) (b *box, inFlight <-chan struct{})
}

func exitCases() []exitCase {
	still := func(made func(t *testing.T) *box) func(*testing.T) (*box, <-chan struct{}) {
		return func(t *testing.T) (*box, <-chan struct{}) { return made(t), nil }
	}
	keep := func(*Config) {}
	taken := func(t *testing.T) *box {
		home, b := aBox(t, keep)
		b.setUp("alice")
		home.accounts.Hold("alice", "per_"+strings.Repeat("0", 64))
		b.post("/saved", nil)
		return b
	}
	earlierRun := func(t *testing.T) (*fakeHome, *box, string) {
		home := newFakeHome(t)
		dir := t.TempDir()
		first := newBox(t, home, dir)
		first.setUp("alice")
		code := first.recovery()
		home.accounts.Down = true
		first.post("/saved", nil)
		return home, newBox(t, home, dir), code
	}
	inFlight := func(b *box, g *gate, t *testing.T, path string, fields url.Values) <-chan struct{} {
		g.shut()
		done := make(chan struct{})
		go func() {
			defer close(done)
			b.post(path, fields)
		}()
		g.reached(t)
		return done
	}
	notTheDial := func(r *http.Request) bool { return !theDial(r) }
	return []exitCase{
		{name: "nothing set up", page: PageSetup, made: still(func(t *testing.T) *box {
			_, b := aBox(t, keep)
			return b
		})},
		{name: "a passphrase drawn", page: PageSetup, made: still(func(t *testing.T) *box {
			_, b := aBox(t, keep)
			b.shown()
			return b
		})},
		{name: "a setup in flight", page: PageSetup, made: func(t *testing.T) (*box, <-chan struct{}) {
			g := newGate(t)
			_, b := aBox(t, gated(g, notTheDial))
			p := b.shown()
			return b, inFlight(b, g, t, "/setup", url.Values{"name": {"alice"}, "secret": {p}, "again": {p}})
		}},
		{name: "a key on no account", page: PageEnroll, made: still(func(t *testing.T) *box {
			_, b, _ := withKey(t, keep)
			return b
		})},
		{name: "a key on no account, its PIN's proof handed out", page: PageEnroll, made: still(func(t *testing.T) *box {
			home, b, p := withKey(t, keep)
			home.accounts.Down = true
			b.post("/create", url.Values{"name": {"alice"}, "secret": {p}})
			if len(b.shell.proof) == 0 {
				t.Fatal("no proof was handed out")
			}
			return b
		})},
		{name: "a recovery code shown and not yet saved", page: PageRecovery, made: still(func(t *testing.T) *box {
			_, b := aBox(t, keep)
			b.setUp("alice")
			return b
		})},
		{name: "that code shown for a key made before", page: PageRecovery, made: still(func(t *testing.T) *box {
			_, b, p := withKey(t, keep)
			b.post("/create", url.Values{"name": {"alice"}, "secret": {p}})
			return b
		})},
		{name: "that code being saved", page: PageRecovery, made: func(t *testing.T) (*box, <-chan struct{}) {
			g := newGate(t)
			_, b := aBox(t, gated(g, notTheDial))
			b.setUp("alice")
			return b, inFlight(b, g, t, "/saved", nil)
		}},
		{name: "the code saved, the account not answered", page: PageAccount, made: still(func(t *testing.T) *box {
			home, b := aBox(t, keep)
			b.setUp("alice")
			home.accounts.Down = true
			b.post("/saved", nil)
			return b
		})},
		{name: "the code saved, the name taken", page: PageName, made: still(taken)},
		{name: "an account an earlier run began", page: PageResume, made: still(func(t *testing.T) *box {
			_, b, _ := earlierRun(t)
			return b
		})},
		{name: "that account, its code typed", page: PageAccount, made: still(func(t *testing.T) *box {
			_, b, code := earlierRun(t)
			b.post("/resume", url.Values{"code": {code}})
			return b
		})},
		{name: "a key held since setup, another's account begun", page: PageResume, made: still(func(t *testing.T) *box {
			_, b := aBox(t, keep)
			b.setUp("alice")
			other := b.shell.making.attempt
			other.Identifier = "per_" + strings.Repeat("7", 64)
			if err := createJSON(b.shell.attemptPath(), other); err != nil {
				t.Fatal(err)
			}
			b.post("/saved", nil)
			if b.shell.key == nil {
				t.Fatal("no key is held")
			}
			return b
		})},
		{name: "locked", page: PageLocked, made: still(func(t *testing.T) *box {
			_, b, _ := opened(t, keep)
			b.shell.Lock(suspendedHere)
			return b
		})},
		{name: "never connected", page: PageLocked, made: still(func(t *testing.T) *box {
			b, _ := neverConnected(t, newFakeHome(t))
			return b
		})},
		{name: "an unlock in flight", page: PageLocked, made: func(t *testing.T) (*box, <-chan struct{}) {
			g := newGate(t)
			b, p := neverConnected(t, newFakeHome(t), gated(g, theDial))
			return b, inFlight(b, g, t, "/unlock", url.Values{"secret": {p}})
		}},
		{name: "unlocked", page: PageUnlocked, made: still(func(t *testing.T) *box {
			_, b, _ := opened(t, keep)
			return b
		})},
		{name: "a confirmation drawn", page: PageConfirm, made: still(func(t *testing.T) *box {
			_, b, _ := confirmDrawn(t, keep, true)
			return b
		})},
		{name: "a passkey drawn", page: PagePasskey, made: still(func(t *testing.T) *box {
			_, b, _, _ := passkeyDrawn(t, keep, true)
			return b
		})},
		{name: "a state nobody listed", page: "unlisted", made: still(func(t *testing.T) *box {
			_, b := aBox(t, keep)
			b.shell.shown.Store(&shownState{view: View{Page: "unlisted"}})
			return b
		})},
	}
}

// The browser's exit is a Lock (cmd runScreenShell), which locks in every
// state, a recovery code shown and not yet saved among them.
func TestExit_LocksInEveryState(t *testing.T) {
	for _, c := range exitCases() {
		t.Run(c.name, func(t *testing.T) {
			b, inFlight := c.made(t)
			s := b.shell
			if page := s.shown.Load().view.Page; page != c.page {
				t.Fatalf("the row made %q, not %q", page, c.page)
			}
			var recovery []byte
			if inFlight == nil && s.making != nil {
				recovery = s.making.key
			}
			wasOpen, restarts, notice := s.Unlocked(), b.restarts.Load(), s.shown.Load().view.Notice
			s.genMu.Lock()
			began := s.gen
			s.genMu.Unlock()

			returns(t, "the browser's exit", func() { s.Lock(browserClosed) })
			if inFlight != nil {
				returns(t, "what was in flight", func() { <-inFlight })
			}
			if began.live() {
				t.Fatal("the exit ended no generation, so it did not lock")
			}
			s.mu.Lock()
			defer s.mu.Unlock()
			if s.key != nil || s.ch != nil || s.making != nil || s.proof != nil || s.passphrase != "" ||
				s.confirm != nil || s.passkey != nil || s.locks != nil || s.open.Load() {
				t.Fatalf("the exit left what a lock ends:\n%s", wholeState(t, b))
			}
			if slices.ContainsFunc(recovery, func(x byte) bool { return x != 0 }) {
				t.Fatal("the recovery key is still in memory")
			}
			if !wasOpen {
				// Restarting the browser from its own exit would never end.
				if b.restarts.Load() != restarts || (inFlight == nil && s.notice != notice) {
					t.Fatalf("a locked device's exit restarted the browser or took its sentence: %q", s.notice)
				}
				return
			}
			if s.notice != browserClosed || b.restarts.Load() != restarts+1 {
				t.Fatalf("an open device's exit said %q and restarted %d times", s.notice, b.restarts.Load()-restarts)
			}
		})
	}
}

// A page added to the shell fails here until the exit's table has its row.
func TestExit_TheTableHoldsEveryPage(t *testing.T) {
	tree, err := parser.ParseFile(token.NewFileSet(), "shell.go", nil, 0)
	if err != nil {
		t.Fatal(err)
	}
	var want, have []Page
	ast.Inspect(tree, func(n ast.Node) bool {
		v, ok := n.(*ast.ValueSpec)
		if !ok {
			return true
		}
		if typ, ok := v.Type.(*ast.Ident); ok && typ.Name == "Page" {
			for _, value := range v.Values {
				if lit, ok := value.(*ast.BasicLit); ok {
					page, err := strconv.Unquote(lit.Value)
					if err != nil {
						t.Fatal(err)
					}
					want = append(want, Page(page))
				}
			}
		}
		return true
	})
	for _, c := range exitCases() {
		if c.page != "unlisted" {
			have = append(have, c.page)
		}
	}
	slices.Sort(want)
	slices.Sort(have)
	if have = slices.Compact(have); len(want) == 0 || !slices.Equal(want, have) {
		t.Fatalf("the shell has the pages %v and the exit's table %v", want, have)
	}
}
