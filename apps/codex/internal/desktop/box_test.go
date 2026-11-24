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
	"strconv"
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
	// unread is whether the folder cannot be read.
	unread atomic.Bool
	mu     sync.Mutex
	log    []string
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
		if b.unread.Load() {
			return Local{}, errors.New("its .env cannot be read")
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
// chooser presses it by itself and the rail shows it first, at the
// address its folder names; its press reads the folder now and opens the CYFR it names,
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
	if got := b.rail(t, 0).CYFRs; len(got) != 1 || got[0] != (RailCYFR{Home: localAddress, Box: true, Folder: boxFolder}) {
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
	// Not even once it is left, the box unlocked as it was.
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

// On a box's screen the list is changed only while the box is unlocked,
// and only for another CYFR than the one open and than This box: the
// rail's read says locked while no CYFR's device is unlocked, every lock
// and every unlock telling it. No permission outlives the unlock it rests
// on: a departure from an unlocked CYFR, to Connect or with a second lock
// on its way, leaves the box locked, and that CYFR's Forget is refused
// like any other's.
func TestABoxForgetsOnlyAnotherWhileUnlocked(t *testing.T) {
	const work, other = "https://work.example.com", "https://other.example.com"
	var open atomic.Bool
	unlockedAs(t, &open)
	b := newOnBox(t)
	seed(t, b.Homes, other, shell.ClientRecord{Directory: account.DefaultDirectory})
	seed(t, b.Homes, work, shell.ClientRecord{Directory: account.DefaultDirectory})
	refused := func(why, home string) {
		t.Helper()
		b.Forget(home)
		b.quiet(t)
		if rec, _ := held(t, b.Homes, home); rec.Forgetting {
			t.Fatalf("%s: %s was marked to be forgotten", why, home)
		}
	}

	b.openBox(t, localAddress)
	if list := b.rail(t, 0); !list.Locked {
		t.Fatalf("a box locked reads %+v", list)
	}
	refused("while the box is locked", other)
	open.Store(true)
	if list := b.rail(t, 0); list.Locked {
		t.Fatalf("a box unlocked reads %+v", list)
	}
	refused("This box", localAddress)
	seen := b.rail(t, 0).Seq
	b.Lock("Locked.")
	b.next(t)
	if list := b.rail(t, seen); list.Seq == seen {
		t.Fatal("the rail did not hear the lock")
	}

	// The CYFR open, unlocked.
	b.Leave(1)
	b.next(t)
	b.next(t)
	selectWork := func() {
		t.Helper()
		done := b.connect(t, "/bootstrap/connect", map[string]string{"address": work, "kept": "true"})
		b.next(t)
		b.ready(work)
		answered(t, done)
		b.opened(t, work)
	}
	selectWork()
	refused("the CYFR open", work)

	// Left for Connect, from unlocked: the chooser's state read, nothing
	// confirmed, the box locked.
	b.Leave(2)
	b.next(t)
	b.next(t)
	open.Store(false)
	b.post(t, "/bootstrap/state", map[string]string{})
	refused("left for Connect", work)

	// Left while a second lock was on its way.
	selectWork()
	open.Store(true)
	b.Leave(3)
	b.Lock("Locked.")
	open.Store(false)
	for range 3 {
		b.next(t)
	}
	refused("left with a second lock on its way", work)

	// Another CYFR, the box unlocked at the CYFR open: forgotten.
	selectWork()
	open.Store(true)
	b.Forget(other)
	b.erases(t, 1)
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

// A departure in flight is waited for by the service's end: the shell it
// left is still retiring its sessions (held here inside that shell's lock,
// after the hide, where its CYFR's answers are awaited), and End returns
// only once that retirement, and with it the work begun for that CYFR,
// has ended.
func TestTheEndWaitsForADepartureInFlight(t *testing.T) {
	b := newOnBox(t)
	var holding atomic.Bool
	release := make(chan struct{})
	b.Shell = func(c *shell.Config) {
		hide := c.Restart
		c.Restart = func() {
			hide()
			if holding.Load() {
				<-release
			}
		}
	}
	b.openBox(t, localAddress)
	w := b.here.Work
	holding.Store(true)
	left := make(chan struct{})
	go func() {
		b.Leave(1)
		close(left)
	}()
	if m := b.next(t); m.Type != TypeLocked {
		t.Fatalf("the departure said %+v", m)
	}
	ended := make(chan struct{})
	go func() {
		b.End()
		close(ended)
	}()
	select {
	case <-ended:
		t.Fatal("End returned while the CYFR left was still retiring its sessions")
	case <-time.After(300 * time.Millisecond): // sleep-ok: End must still be waiting after a while, which nothing else shows
	}
	close(release)
	select {
	case <-ended:
	case <-time.After(5 * time.Second):
		t.Fatal("End did not return once the departure retired")
	}
	if w.Context().Err() == nil {
		t.Fatal("End returned before the work of the CYFR left ended")
	}
	<-left
}

// Every lock on a box is one step of the service's: the time since the
// last lock ends, and main is told locked through the hide, in one hold,
// so nothing of a selection begun after it is told before its locked; a
// lock from the device's own page (Prism's Lock, at loopback /lock) is
// that same step as the idle lock: each moves the epoch, and a chooser
// request carrying the epoch before it publishes nothing.
func TestEveryLockOnABoxIsOneStep(t *testing.T) {
	b := newOnBox(t)
	marking, release := make(chan struct{}), make(chan struct{})
	var held atomic.Bool
	held.Store(true)
	b.Hide = func(tell func()) {
		b.note("hidden")
		if held.CompareAndSwap(true, false) {
			close(marking)
			<-release
		}
		tell()
	}
	locked := make(chan struct{})
	go func() {
		b.Lock("Locked.")
		close(locked)
	}()
	<-marking
	done := b.connect(t, "/bootstrap/box", map[string]string{"epoch": "1"})
	time.Sleep(200 * time.Millisecond) // sleep-ok: a press must stay unpublished while the lock is told, which nothing else shows
	b.quiet(t)
	close(release)
	<-locked
	if m := b.next(t); m.Type != TypeLocked {
		t.Fatalf("a press begun after the lock was told first: %+v", m)
	}
	if m := b.next(t); m.Type != TypeHome {
		t.Fatalf("the press then proposed %+v", m)
	}
	b.ready(localAddress)
	answered(t, done)
	b.opened(t, localAddress)

	// A CYFR elsewhere open: Prism's Lock and the idle lock alike.
	const work = "https://work.example.com"
	b.Leave(1)
	b.next(t)
	b.next(t)
	sel := b.connect(t, "/bootstrap/connect", map[string]string{"address": work})
	b.next(t)
	b.ready(work)
	answered(t, sel)
	b.opened(t, work)
	for name, lock := range map[string]func(){
		"Prism's Lock":  func() { b.get("/lock") },
		"the idle lock": func() { b.Lock("Locked after five minutes without use.") },
	} {
		before := b.post(t, "/bootstrap/state", map[string]string{}).Epoch
		lock()
		if m := b.next(t); m.Type != TypeLocked || m.Home != work {
			t.Fatalf("%s said %+v", name, m)
		}
		if after := b.post(t, "/bootstrap/state", map[string]string{}).Epoch; after != before+1 {
			t.Fatalf("%s moved the epoch from %d to %d", name, before, after)
		}
		got := b.post(t, "/bootstrap/connect", map[string]string{"address": work, "epoch": strconv.FormatUint(before, 10)})
		if got.Error != lockedSentence {
			t.Fatalf("after %s a request of the epoch before it answered %+v", name, got)
		}
	}
}

// This box is the CYFR its folder names at each reading, never the entry
// made or admitted last: its folder at A, then B, then A again, the rail
// shows A as This box and Forget, the box unlocked, keeps A and forgets B.
// A list that cannot be read still shows This box; a folder that cannot be
// read protects every entry set up in it.
func TestThisBoxIsWhatItsFolderNamesNow(t *testing.T) {
	const moved = "http://localhost:4402"
	var open atomic.Bool
	unlockedAs(t, &open)
	b := newOnBox(t)
	for i, at := range []string{localAddress, moved, localAddress} {
		if i > 0 {
			b.Leave(uint64(i))
			b.next(t)
			b.next(t)
		}
		b.at.Store(at)
		b.openBox(t, at)
	}
	if rail := b.rail(t, 0).CYFRs; rail[0] != (RailCYFR{Home: localAddress, Box: true, Folder: boxFolder, Open: true}) {
		t.Fatalf("after A, B, A the rail shows %+v", rail)
	}
	open.Store(true)
	b.Forget(localAddress)
	b.quiet(t)
	if rec, _ := held(t, b.Homes, localAddress); rec.Forgetting {
		t.Fatal("This box, as its folder names it now, was marked to be forgotten")
	}
	b.unread.Store(true)
	b.Forget(moved)
	b.quiet(t)
	if rec, _ := held(t, b.Homes, moved); rec.Forgetting {
		t.Fatal("an entry of a folder that cannot be read was marked to be forgotten")
	}
	b.unread.Store(false)
	b.Forget(moved)
	b.erases(t, 2) // its content and the ceremony its opening recorded

	if err := os.WriteFile(string(b.Homes), []byte("{"), 0o600); err != nil {
		t.Fatal(err)
	}
	got := b.rail(t, 0)
	if got.Error == "" || len(got.CYFRs) != 1 || got.CYFRs[0].Home != localAddress || !got.CYFRs[0].Box {
		t.Fatalf("a list that cannot be read shows %+v", got)
	}
}

// A lock while the device's page of a CYFR elsewhere waits on that CYFR's
// account service (its terms, up to 3 s) is taken at once: the page's read
// holds nothing the lock needs, and the lock ends it.
func TestALockDuringAnEnrolmentPageIsTakenAtOnce(t *testing.T) {
	b := newOnBox(t)
	b.openBox(t, localAddress)
	b.answered(t)
	drawn := codeShape.FindStringSubmatch(b.form("/passphrase", nil).Body.String())
	if drawn == nil {
		t.Fatal("no passphrase drawn")
	}
	b.form("/make", url.Values{"secret": {drawn[1]}, "again": {drawn[1]}})
	b.Leave(1)
	b.next(t)
	b.next(t)
	asked := make(chan struct{})
	var once sync.Once
	b.Client = &http.Client{Transport: roundTrip(func(r *http.Request) (*http.Response, error) {
		once.Do(func() { close(asked) })
		<-r.Context().Done()
		return nil, r.Context().Err()
	})}
	const work = "https://work.example.com"
	done := b.connect(t, "/bootstrap/connect", map[string]string{"address": work})
	b.next(t)
	b.ready(work)
	answered(t, done)
	b.opened(t, work)
	read := make(chan struct{})
	go func() {
		b.get("/")
		close(read)
	}()
	<-asked
	b.said()
	start := time.Now()
	b.Lock("Locked.")
	if took := time.Since(start); took > 500*time.Millisecond || b.said() != "hidden, locked" {
		t.Fatalf("a lock during the page's wait took %v", took)
	}
	select {
	case <-read:
	case <-time.After(time.Second):
		t.Fatal("the page went on waiting after the lock")
	}
}
