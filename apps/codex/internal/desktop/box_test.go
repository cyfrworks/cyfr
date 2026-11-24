// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package desktop

import (
	"context"
	"errors"
	"io/fs"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/cyfr/codex/internal/account"
	"github.com/cyfr/codex/internal/shell"
)

const boxFolder = "/home/box/cyfr"

// onBox is a over a box's screen whose folder (Box) names the address
// *at, whose CYFR answers while answers holds, every lock of it hidden
// through a hide that writes "hidden" to the log before it tells main,
// whose messages are logged by type too.
type onBox struct {
	*app
	at      atomic.Value
	answers atomic.Bool
	// tokens counts the reads of the folder's setup token.
	tokens atomic.Int32
	// hangs holds every ask whether its CYFR answers until the asker ends.
	hangs atomic.Bool
	mu    sync.Mutex
	log   []string
}

func newOnBox(t *testing.T) *onBox {
	t.Helper()
	b := &onBox{app: newApp(t, t.TempDir(), offline())}
	b.at.Store(localAddress)
	b.answers.Store(true)
	b.Box = boxFolder
	tell := b.Tell
	b.Tell = func(m Message) {
		b.note(m.Type)
		tell(m)
	}
	b.Hide = func(tell func()) {
		b.note("hidden")
		tell()
	}
	b.Local = func(project string) (Local, error) {
		if project != boxFolder {
			t.Errorf("the box read %s, not its folder", project)
		}
		return Local{Shell: shell.Config{Address: b.at.Load().(string), Client: offline(), Directory: account.DefaultDirectory,
			SetupToken: func(context.Context) (string, http.RoundTripper) {
				b.tokens.Add(1)
				return strings.Repeat("cd", 32), nil
			}},
			Answers: func(ctx context.Context) error {
				if b.hangs.Load() {
					<-ctx.Done()
					return ctx.Err()
				}
				if b.answers.Load() {
					return nil
				}
				return errors.New("CYFR is not running in " + boxFolder + ".")
			}, Work: shell.NewWork(t.Context())}, nil
	}
	return b
}

func (b *onBox) note(what string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.log = append(b.log, what)
}

// said is what the log holds since the last said, joined.
func (b *onBox) said() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	out := strings.Join(b.log, ", ")
	b.log = nil
	return out
}

// openBox presses This box and answers its proposal, which must name
// home, as main does.
func (b *onBox) openBox(t *testing.T, home string) {
	t.Helper()
	done := b.connect(t, "/bootstrap/box", map[string]string{})
	if m := b.next(t); m.Type != TypeHome || m.Home != home || m.Setup != "" {
		t.Fatalf("This box proposed %+v, not %s with no setup token", m, home)
	}
	b.ready(home)
	if got := answered(t, done); got.Next != "/" {
		t.Fatalf("This box's press answered %+v", got)
	}
	b.opened(t, home)
}

// answered is This box's page once its reading said it answers: the
// pages read it apart, and show it starting until then.
func (b *onBox) answered(t *testing.T) string {
	t.Helper()
	for deadline := time.Now().Add(5 * time.Second); ; {
		page := b.get("/").Body.String()
		if !strings.Contains(page, "CYFR is starting") || time.Now().After(deadline) {
			return page
		}
		time.Sleep(10 * time.Millisecond) // sleep-ok: polls the pages' own reading, which runs apart
	}
}

// Every lock on a box's screen hides what it shows before main is told:
// with no CYFR open, with This box open, a departure's, and the service's
// end, whose hide says ending in place of locked, once; nothing is said
// after it.
func TestEveryLockOnABoxHidesBeforeMainIsTold(t *testing.T) {
	b := newOnBox(t)
	b.Lock("Locked after five minutes without use.")
	if got := b.said(); got != "hidden, locked" {
		t.Fatalf("a lock with no CYFR open: %s", got)
	}
	b.next(t)
	b.openBox(t, localAddress)
	b.said()
	b.Lock("Locked.")
	if got := b.said(); got != "hidden, locked" {
		t.Fatalf("a lock with This box open: %s", got)
	}
	if m := b.next(t); m.Type != TypeLocked || m.Home != localAddress {
		t.Fatalf("the lock named %+v", m)
	}
	b.Leave(1)
	if got := b.said(); got != "hidden, locked, left" {
		t.Fatalf("a departure: %s", got)
	}
	b.next(t)
	b.next(t)
	b.End()
	b.End()
	b.Leave(2)
	b.Lock("Locked.")
	if got := b.said(); got != "hidden, ending" {
		t.Fatalf("the end: %s", got)
	}
	b.next(t)
	b.quiet(t)
}

// This box is no row of the list: on a first start, with no entry, the
// chooser presses it by itself and the rail shows it first with no
// address; its press reads the folder now and opens the CYFR it names,
// waiting for it to answer rather than refusing; after a lock the last
// selected is offered instead. A folder at a new address opens that address
// as an entry of its own, the entry the old reading made left as it was
// and shown as a row of its own, which Forget forgets, the box unlocked,
// while This box's is never forgotten.
func TestThisBoxOpensWhatItsFolderNamesNow(t *testing.T) {
	b := newOnBox(t)
	if got := b.post(t, "/bootstrap/state", map[string]string{}); got != (answer{ResumeBox: true}) {
		t.Fatalf("a first start shows %+v", got)
	}
	if got := b.rail(t, 0).CYFRs; len(got) != 1 || got[0] != (RailCYFR{Box: true, Folder: boxFolder}) {
		t.Fatalf("a first start's rail shows %+v", got)
	}
	b.answers.Store(false)
	b.openBox(t, localAddress)
	if w := b.get("/"); w.Code != http.StatusOK || !strings.Contains(w.Body.String(), "CYFR is starting") {
		t.Fatalf("This box not answering yet does not wait for it: %d %s", w.Code, w.Body)
	}
	b.answers.Store(true)
	if got := b.rail(t, 0).CYFRs; len(got) != 1 || got[0] != (RailCYFR{Home: localAddress, Box: true, Folder: boxFolder, Open: true}) {
		t.Fatalf("the rail shows %+v", got)
	}
	old, _ := held(t, b.Homes, localAddress)

	const moved = "http://localhost:4402"
	b.Leave(1)
	b.next(t)
	b.next(t)
	b.at.Store(moved)
	b.openBox(t, moved)
	if was, _ := held(t, b.Homes, localAddress); !sameEntry(was, old) || was.Generation != old.Generation {
		t.Fatalf("the old reading's entry changed: %+v, was %+v", was, old)
	}
	if now, ok := held(t, b.Homes, moved); !ok || now.Project != boxFolder || now.ClientID != "" {
		t.Fatalf("the new address's entry is %+v", now)
	}
	rail := b.rail(t, 0).CYFRs
	if len(rail) != 2 || rail[0] != (RailCYFR{Home: moved, Box: true, Folder: boxFolder, Open: true}) ||
		rail[1] != (RailCYFR{Home: localAddress, Folder: boxFolder}) {
		t.Fatalf("the rail shows %+v", rail)
	}
	var open atomic.Bool
	open.Store(true)
	unlockedAs(t, &open)
	b.Forget(localAddress)
	b.erases(t, 2)
	// Not even as the CYFR a departure from its unlocked device just left.
	b.Leave(2)
	b.next(t)
	b.next(t)
	b.Forget(moved)
	b.quiet(t)
	if rec, ok := held(t, b.Homes, moved); !ok || rec.Forgetting {
		t.Fatalf("This box's entry was forgotten: %+v", rec)
	}
}

// After a CYFR was selected, a box's start offers it, not This box.
func TestABoxOffersTheLastSelectedOverThisBox(t *testing.T) {
	b := newOnBox(t)
	seed(t, b.Homes, "https://work.example.com", shell.ClientRecord{Directory: account.DefaultDirectory})
	if got := b.post(t, "/bootstrap/state", map[string]string{}); got != (answer{Home: "https://work.example.com", Resume: "https://work.example.com"}) {
		t.Fatalf("a start shows %+v", got)
	}
}

// On a box's screen only This box's shell makes the machine's key: on a
// new box, a CYFR elsewhere opened first shows where the key is made,
// offers no way to make it there and makes none, whatever is posted; This
// box then opens for its owner and makes it. A desktop's shell makes it at
// a CYFR elsewhere.
func TestOnlyThisBoxMakesTheKey(t *testing.T) {
	const work = "https://work.example.com"
	b := newOnBox(t)
	done := b.connect(t, "/bootstrap/connect", map[string]string{"address": work})
	b.next(t)
	b.ready(work)
	answered(t, done)
	b.opened(t, work)
	if page := b.get("/").Body.String(); !strings.Contains(page, "This box makes its key") || strings.Contains(page, `action="/passphrase"`) {
		t.Fatalf("a CYFR elsewhere on a new box offers to make the key:\n%s", page)
	}
	pass := "correct horse battery staple again twice"
	if drawn := codeShape.FindStringSubmatch(b.form("/passphrase", nil).Body.String()); drawn != nil {
		pass = drawn[1]
	}
	for _, path := range []string{"/make", "/setup"} {
		b.form(path, url.Values{"name": {"alice"}, "secret": {pass}, "again": {pass}})
	}
	if _, err := os.Stat(b.Record); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("a key was made at a CYFR elsewhere (%v)", err)
	}
	if page := b.get("/").Body.String(); !strings.Contains(page, "This box makes its key") {
		t.Fatalf("the refusal does not say where the key is made:\n%s", page)
	}
	b.Leave(1)
	b.next(t)
	b.next(t)
	b.openBox(t, localAddress)
	if page := b.answered(t); strings.Contains(page, "This box makes its key") || !strings.Contains(page, `action="/passphrase"`) {
		t.Fatalf("This box does not offer to make the key:\n%s", page)
	}
	drawn := codeShape.FindStringSubmatch(b.form("/passphrase", nil).Body.String())
	if drawn == nil {
		t.Fatal("This box drew no passphrase")
	}
	b.form("/make", url.Values{"secret": {drawn[1]}, "again": {drawn[1]}})
	if _, err := os.Stat(b.Record); err != nil {
		t.Fatalf("This box made no key (%v)", err)
	}

	a := newApp(t, t.TempDir(), offline())
	done = a.connect(t, "/bootstrap/connect", map[string]string{"address": work})
	a.next(t)
	a.ready(work)
	answered(t, done)
	a.opened(t, work)
	if page := a.get("/").Body.String(); strings.Contains(page, "This box makes its key") || !strings.Contains(page, `action="/passphrase"`) {
		t.Fatalf("a desktop does not offer to make the key at a CYFR elsewhere:\n%s", page)
	}
}

// unlockedAs stands in for whether a device's shell is unlocked, by open,
// for the test.
func unlockedAs(t *testing.T, open *atomic.Bool) {
	t.Helper()
	was := unlocked
	unlocked = func(*shell.Shell) bool { return open.Load() }
	t.Cleanup(func() { unlocked = was })
}

// On a box's screen the list is changed only while the box is unlocked:
// the rail's read says locked while no CYFR's device is unlocked, every
// lock telling it; a Forget while locked forgets nothing, and This box's
// none ever. A CYFR open and unlocked forgets another; its own Forget,
// which main sends once it left it, is the one the departure from its
// unlocked device allows, once, and no lock after the departure lets it.
func TestABoxForgetsOnlyWhileUnlocked(t *testing.T) {
	const work, other = "https://work.example.com", "https://other.example.com"
	var open atomic.Bool
	unlockedAs(t, &open)
	b := newOnBox(t)
	seed(t, b.Homes, other, shell.ClientRecord{Directory: account.DefaultDirectory})
	b.openBox(t, localAddress)
	if list := b.rail(t, 0); !list.Locked {
		t.Fatalf("a box locked reads %+v", list)
	}
	b.Forget(other)
	b.quiet(t)
	open.Store(true)
	seen := b.rail(t, 0).Seq
	if list := b.rail(t, 0); list.Locked {
		t.Fatalf("a box unlocked reads %+v", list)
	}
	b.Forget(localAddress)
	b.quiet(t)
	b.Forget(other)
	b.erases(t, 1)
	seen = b.rail(t, 0).Seq
	b.Lock("Locked.")
	b.next(t)
	if list := b.rail(t, seen); list.Seq == seen {
		t.Fatal("the rail did not hear the lock")
	}

	// Its own Forget, once it was left unlocked.
	seed(t, b.Homes, work, shell.ClientRecord{Directory: account.DefaultDirectory})
	open.Store(false)
	b.Leave(1)
	b.next(t)
	b.next(t)
	done := b.connect(t, "/bootstrap/connect", map[string]string{"address": work, "kept": "true"})
	b.next(t)
	b.ready(work)
	answered(t, done)
	b.opened(t, work)
	open.Store(true)
	b.Leave(2)
	b.next(t)
	b.next(t)
	open.Store(false)
	b.Lock("Locked.")
	b.next(t)
	b.Forget(work)
	b.quiet(t)
	if rec, _ := held(t, b.Homes, work); rec.Forgetting {
		t.Fatal("a lock after the departure let its Forget through")
	}

	done = b.connect(t, "/bootstrap/connect", map[string]string{"address": work, "kept": "true"})
	b.next(t)
	b.ready(work)
	answered(t, done)
	b.opened(t, work)
	open.Store(true)
	b.Leave(3)
	b.next(t)
	b.next(t)
	open.Store(false)
	b.Forget(work)
	b.erases(t, 2)
	b.Forget(work)
	b.erases(t, 2)
}

// A box's selections start locked and nothing late of one publishes: This
// box opened shows the device's own page, unlocked by nothing and handing
// no ticket on; a press answered after a lock opens nothing; and its
// setup token is read only at the device's first hello, never at the
// press. A CYFR elsewhere gets nothing of the box's folder: no work begun
// for it, no setup token, the folder unread.
func TestABoxsSelectionsStartLockedAndGiveACYFRElsewhereNothing(t *testing.T) {
	b := newOnBox(t)
	b.openBox(t, localAddress)
	if page := b.answered(t); b.sh.Unlocked() || strings.Contains(page, "data-to=") {
		t.Fatalf("This box opened unlocked, or handed a ticket on:\n%s", page)
	}
	if n := b.tokens.Load(); n != 0 {
		t.Fatalf("This box's press read its setup token %d times", n)
	}
	// A press waits on no CYFR: with its CYFR never answering, This box
	// opens all the same.
	b.hangs.Store(true)
	b.Leave(1)
	b.next(t)
	b.next(t)
	b.openBox(t, localAddress)
	b.hangs.Store(false)
	b.Leave(2)
	b.next(t)
	b.next(t)

	done := b.connect(t, "/bootstrap/box", map[string]string{})
	b.next(t)
	b.Lock("Locked.")
	b.next(t)
	b.ready(localAddress)
	if got := answered(t, done); got.Next != "" {
		t.Fatalf("a press answered after a lock opened: %+v", got)
	}
	b.quiet(t)

	reads := 0
	read := b.Local
	b.Local = func(project string) (Local, error) { reads++; return read(project) }
	done = b.connect(t, "/bootstrap/connect", map[string]string{"address": "https://work.example.com"})
	if m := b.next(t); m.Type != TypeHome || m.Setup != "" || m.Proxy != "" {
		t.Fatalf("a CYFR elsewhere was proposed %+v", m)
	}
	b.ready("https://work.example.com")
	answered(t, done)
	b.opened(t, "https://work.example.com")
	b.Service.mu.Lock()
	here := b.here
	b.Service.mu.Unlock()
	if here != nil || reads != 0 || b.tokens.Load() != 0 {
		t.Fatalf("a CYFR elsewhere got the box's folder: its work %v, %d readings, %d setup tokens", here, reads, b.tokens.Load())
	}
}

// What This box's selection begins is that selection's own: its Work ends
// as the box leaves it, as a selection of it that does not open ends (a
// lock before main answered), and as the service ends, while the service,
// its listener and the watches above it, goes on to open This box again.
func TestThisBoxsWorkEndsWithItsSelection(t *testing.T) {
	b := newOnBox(t)
	works := make(chan *shell.Work, 8)
	local := b.Local
	b.Local = func(project string) (Local, error) {
		l, err := local(project)
		works <- l.Work
		return l, err
	}
	ends := func(what string, w *shell.Work) {
		t.Helper()
		select {
		case <-w.Context().Done():
		case <-time.After(5 * time.Second):
			t.Fatalf("This box's work outlived %s", what)
		}
	}
	lives := func(what string, w *shell.Work) {
		t.Helper()
		if w.Context().Err() != nil {
			t.Fatalf("This box's work ended %s", what)
		}
	}

	b.openBox(t, localAddress)
	w := <-works
	lives("while it is open", w)
	b.Leave(1)
	b.next(t)
	b.next(t)
	ends("the departure from it", w)

	done := b.connect(t, "/bootstrap/box", map[string]string{})
	if m := b.next(t); m.Type != TypeHome {
		t.Fatalf("This box proposed %+v", m)
	}
	w = <-works
	b.Lock("Locked.")
	if got := answered(t, done); got.Error == "" {
		t.Fatalf("a selection a lock cut short answered %+v", got)
	}
	b.next(t)
	ends("its selection that did not open", w)

	b.openBox(t, localAddress)
	w = <-works
	lives("while it is open again", w)
	b.End()
	ends("the service's end", w)
}
