// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package desktop

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/cyfr/codex/internal/account"
	"github.com/cyfr/codex/internal/shell"
)

// updating is a over Update CYFR's stand-ins: each offer is plan, numbered
// by the service, with the folder it was asked for recorded; each start
// is recorded with the record it was given, and runs until its end is
// let go (finish).
type updatingApp struct {
	*app
	mu       sync.Mutex
	asked    []string
	begun    []UpdatePlan
	records  []string
	ends     chan error
	refuse   error
	runsLock atomic.Bool
}

func newUpdating(t *testing.T, a *app, plan UpdatePlan) *updatingApp {
	t.Helper()
	u := &updatingApp{app: a, ends: make(chan error, 4)}
	a.UpdateRecord = filepath.Join(t.TempDir(), "update.log")
	a.Offer = func(_ context.Context, project string) UpdatePlan {
		u.mu.Lock()
		u.asked = append(u.asked, project)
		u.mu.Unlock()
		return plan
	}
	a.BeginUpdate = func(p UpdatePlan, record *os.File) (func() error, error) {
		u.mu.Lock()
		defer u.mu.Unlock()
		if u.refuse != nil {
			return nil, u.refuse
		}
		u.begun = append(u.begun, p)
		u.records = append(u.records, record.Name())
		return func() error { return <-u.ends }, nil
	}
	a.UpdateRuns = func(string) bool { return u.runsLock.Load() }
	t.Cleanup(func() {
		close(u.ends)
		a.End()
	})
	return u
}

// readUpdate is the page's read, seen the change it last showed, with
// token.
func (a *app) readUpdate(ctx context.Context, token string, seen uint64) *httptest.ResponseRecorder {
	raw, _ := json.Marshal(map[string]any{"token": token, "seen": seen})
	r := httptest.NewRequestWithContext(ctx, http.MethodPost, "http://"+shell.Listen+"/update/read", strings.NewReader(string(raw)))
	r.Host = shell.Listen
	r.Header.Set("Origin", shell.Origin)
	r.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	a.ServeHTTP(w, r)
	return w
}

// shown is the page's read once it shows what want accepts, within 10 s.
func (a *app) shown(t *testing.T, want func(updateRead) bool) updateRead {
	t.Helper()
	bound := time.Now().Add(10 * time.Second)
	seen := uint64(0)
	for time.Now().Before(bound) {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		w := a.readUpdate(ctx, a.ReadToken, seen)
		cancel()
		var got updateRead
		if w.Code == http.StatusOK && w.Body.Len() > 0 {
			if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
				t.Fatalf("the read answered %s", w.Body)
			}
			if want(got) {
				return got
			}
			seen = got.Seq
		}
	}
	t.Fatal("the page never showed what was awaited")
	return updateRead{}
}

func offeredAs(id uint64) func(updateRead) bool {
	return func(r updateRead) bool { return r.Offer != nil && r.Offer.ID == id }
}

var appPlan = UpdatePlan{UpdateOffer: UpdateOffer{App: "0.0.1", Target: "0.0.2", Step: "app", Says: []string{"Updating closes this app."}},
	Dir: "/the/device", Args: []string{"update", "--version", "0.0.2"}}

// Update CYFR's page and its read take the read token and carry neither
// token; the run token reads nothing there, and the read token starts
// nothing: the yes is main's update alone.
func TestUpdateCYFRsReadTakesTheReadTokenAlone(t *testing.T) {
	a := newApp(t, t.TempDir(), offline())
	u := newUpdating(t, a, appPlan)
	page := a.get("/update/")
	if page.Code != http.StatusOK || strings.Contains(page.Body.String(), a.Token) || strings.Contains(page.Body.String(), a.ReadToken) ||
		!strings.Contains(page.Header().Get("Content-Security-Policy"), "default-src 'none'") {
		t.Fatalf("the page answered %d %v", page.Code, page.Header())
	}
	if !strings.HasSuffix(a.UpdateURL(), "/update/#read="+a.ReadToken) || strings.Contains(a.UpdateURL(), a.Token) {
		t.Fatalf("the page's address is %s", a.UpdateURL())
	}
	for _, token := range []string{a.Token, "", "the-read-token-not"} {
		if w := a.readUpdate(context.Background(), token, 0); w.Code != http.StatusForbidden {
			t.Errorf("the read with %q answered %d", token, w.Code)
		}
	}
	got := a.shown(t, offeredAs(1))
	if want := appPlan.UpdateOffer; got.Offer.App != want.App || got.Offer.Target != want.Target || !reflect.DeepEqual(got.Offer.Says, want.Says) {
		t.Fatalf("the page shows %+v", got.Offer)
	}
	if body := a.readUpdate(context.Background(), a.ReadToken, 0).Body.String(); strings.Contains(body, "/the/device") || strings.Contains(body, "--version") {
		t.Fatalf("the read gives the page what the run is: %s", body)
	}
	if !reflect.DeepEqual(u.asked, []string{""}) {
		t.Fatalf("the offer was worked out for %q, not for no CYFR of this computer's", u.asked)
	}
	for path := range chooserRoutes {
		body := map[string]string{"token": a.ReadToken, "address": "https://other.example.com", "epoch": "0"}
		if w := a.request(context.Background(), path, body, nil); w.Code != http.StatusForbidden {
			t.Errorf("%s with the read token answered %d", path, w.Code)
		}
	}
	if len(u.begun) != 0 {
		t.Fatal("a read started an update")
	}
}

// Only the offer held starts, by its number, and only once: a yes naming
// another number, one repeated, one to an offer with no yes to give, and
// one for an offer dropped since start nothing. The run's record is made
// anew, for this account alone. Once the run ends the offer is dropped,
// and the next is worked out.
func TestOnlyTheOfferHeldStartsAndOnlyOnce(t *testing.T) {
	a := newApp(t, t.TempDir(), offline())
	u := newUpdating(t, a, appPlan)
	if err := os.WriteFile(a.UpdateRecord, []byte("the last update's\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	a.shown(t, offeredAs(1))
	a.StartUpdate(2)
	a.StartUpdate(0)
	if len(u.begun) != 0 {
		t.Fatal("a yes to an offer not held started")
	}
	a.StartUpdate(1)
	a.StartUpdate(1)
	if len(u.begun) != 1 || !reflect.DeepEqual(u.begun[0], UpdatePlan{UpdateOffer: UpdateOffer{ID: 1, App: "0.0.1", Target: "0.0.2", Step: "app",
		Says: appPlan.Says}, Dir: appPlan.Dir, Args: appPlan.Args}) {
		t.Fatalf("started %+v", u.begun)
	}
	if u.records[0] != a.UpdateRecord {
		t.Fatalf("the run's output is %s", u.records[0])
	}
	data, err := os.ReadFile(a.UpdateRecord)
	if err != nil || len(data) != 0 {
		t.Fatalf("the record holds %q (%v)", data, err)
	}
	if info, _ := os.Stat(a.UpdateRecord); runtime.GOOS != "windows" && info.Mode().Perm() != 0o600 {
		t.Fatalf("the record's mode is %v", info.Mode())
	}
	a.shown(t, func(r updateRead) bool { return r.Running })
	u.ends <- errors.New("exit status 1")
	a.shown(t, offeredAs(2))
	a.StartUpdate(1)
	if len(u.begun) != 1 {
		t.Fatal("a late yes to the offer dropped started")
	}

	none := newApp(t, t.TempDir(), offline())
	nu := newUpdating(t, none, UpdatePlan{UpdateOffer: UpdateOffer{App: "0.0.2", Says: []string{"This CYFR app is release 0.0.2, the newest."}}})
	none.shown(t, offeredAs(1))
	none.StartUpdate(1)
	if len(nu.begun) != 0 {
		t.Fatal("an offer with no yes to give started")
	}
}

// A run that cannot start says why on the page, and its offer starts
// nothing again.
func TestARunThatCannotStartSaysWhy(t *testing.T) {
	a := newApp(t, t.TempDir(), offline())
	u := newUpdating(t, a, appPlan)
	u.refuse = errors.New("The update could not be started apart from this app (Access is denied.); nothing was changed. Run 'cyfr update' in a terminal instead")
	a.shown(t, offeredAs(1))
	a.StartUpdate(1)
	got := a.shown(t, func(r updateRead) bool { return r.Refused != "" })
	if got.Refused != u.refuse.Error() || got.Running {
		t.Fatalf("the page shows %+v", got)
	}
	u.refuse = nil
	a.StartUpdate(1)
	if len(u.begun) != 0 {
		t.Fatal("the refused offer started on a second yes")
	}
	a.UpdateClosed()
	if got := a.shown(t, offeredAs(2)); got.Refused != "" {
		t.Fatalf("the refusal outlived its window: %+v", got)
	}
}

// An offer is the CYFR's selected at a time: a lock drops it, and so does
// opening a CYFR; the next is worked out for this computer's own CYFR,
// its folder, once that is the one open.
func TestAnOfferIsDroppedAtALockAndAtASelection(t *testing.T) {
	var running atomic.Bool
	running.Store(true)
	a := rememberLocal(t, t.TempDir(), account.DefaultDirectory, &running)
	u := newUpdating(t, a, appPlan)
	a.shown(t, offeredAs(1))
	a.Lock("Locked.")
	a.next(t)
	a.StartUpdate(1)
	if len(u.begun) != 0 {
		t.Fatal("a yes to an offer a lock dropped started")
	}
	a.shown(t, offeredAs(2))
	a.openedFolder(t)
	a.StartUpdate(2)
	if len(u.begun) != 0 {
		t.Fatal("a yes to an offer made before a CYFR opened started")
	}
	a.shown(t, offeredAs(3))
	u.mu.Lock()
	defer u.mu.Unlock()
	if !reflect.DeepEqual(u.asked, []string{"", "", localFolder}) {
		t.Fatalf("the offers were worked out for %q", u.asked)
	}
}

// Once the window closed, no offer is worked out until a page reads from
// its start: the read of the page closing, woken by its close, works out
// none, so the next window's offer is worked out as it opens.
func TestAClosedWindowsLastReadWorksOutNoOffer(t *testing.T) {
	a := newApp(t, t.TempDir(), offline())
	u := newUpdating(t, a, appPlan)
	first := a.shown(t, offeredAs(1))
	a.UpdateClosed()
	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancel()
	a.readUpdate(ctx, a.ReadToken, first.Seq)
	// The work begins in the read's own hold, before it answers.
	a.mu.Lock()
	working, held := a.update.working, a.update.offer != nil
	a.mu.Unlock()
	if working || held {
		t.Fatalf("the closing page's read worked out an offer (working %v, held %v)", working, held)
	}
	if got := a.shown(t, offeredAs(2)); got.Offer == nil {
		t.Fatal("the next window's first read worked out no offer")
	}
	u.mu.Lock()
	defer u.mu.Unlock()
	if len(u.asked) != 2 {
		t.Fatalf("offers worked out: %d", len(u.asked))
	}
}

// The shell's own lock, the device's (its Lock, its idle lock, its
// channel's end), drops the offer as the service's does.
func TestTheShellsOwnLockDropsTheOffer(t *testing.T) {
	var running atomic.Bool
	running.Store(true)
	a := rememberLocal(t, t.TempDir(), account.DefaultDirectory, &running)
	u := newUpdating(t, a, appPlan)
	a.openedFolder(t)
	offer := a.shown(t, func(r updateRead) bool { return r.Offer != nil }).Offer
	a.sh.Lock("Device locked.")
	a.StartUpdate(offer.ID)
	if len(u.begun) != 0 {
		t.Fatal("a yes to an offer from before the shell's lock started")
	}
}

// The record is the last update's, kept until the next update replaces
// it: the window's close removes nothing, and the page is given it with
// when it was last written and its sum, the refusal cyfr ended on or else
// the last line it said.
func TestTheLastRecordStaysUntilTheNextUpdate(t *testing.T) {
	a := newApp(t, t.TempDir(), offline())
	newUpdating(t, a, appPlan)
	record := "Updating the CYFR app from 0.0.1 to 0.0.2...\nThe CYFR app is release 0.0.2.\n"
	if err := os.WriteFile(a.UpdateRecord, []byte(record), 0o600); err != nil {
		t.Fatal(err)
	}
	at := time.Date(2026, 11, 25, 12, 0, 0, 0, time.UTC)
	if err := os.Chtimes(a.UpdateRecord, at, at); err != nil {
		t.Fatal(err)
	}
	got := a.shown(t, func(r updateRead) bool { return r.Record != "" })
	if got.Record != record || got.At != "2026-11-25 12:00 UTC" || got.Outcome != "The CYFR app is release 0.0.2." || got.Running {
		t.Fatalf("the page shows %+v", got)
	}
	a.UpdateClosed()
	if data, err := os.ReadFile(a.UpdateRecord); err != nil || string(data) != record {
		t.Fatalf("the window's close left the record %q (%v)", data, err)
	}
	for text, want := range map[string]string{
		"Updating the CYFR app from 0.0.1 to 0.0.3...\nError: The CYFR app of release 0.0.3 did not verify (x); nothing was changed and CYFR runs as it did\n": "The CYFR app of release 0.0.3 did not verify (x); nothing was changed and CYFR runs as it did",
		"Updated to release 0.0.2.\n\n": "Updated to release 0.0.2.",
		"":                              "The update ended without saying how.",
	} {
		if got := outcome(text, false); got != want {
			t.Errorf("%q is summed up as %q", text, got)
		}
		if got := outcome(text, true); got != "CYFR is being updated." {
			t.Errorf("a running %q is summed up as %q", text, got)
		}
	}
}

// Whether an update runs is read from the locks an update holds alone,
// never from what the record says: a read begun while one ran answers
// once its lock is let go, the locks asked again while it waits, and one
// begun after answers at once.
func TestAnUpdateRunsWhileItsLockIsHeld(t *testing.T) {
	saved := runsPoll
	t.Cleanup(func() { runsPoll = saved })
	runsPoll = 20 * time.Millisecond
	a := newApp(t, t.TempDir(), offline())
	u := newUpdating(t, a, appPlan)
	if err := os.WriteFile(a.UpdateRecord, []byte("Updated to release 0.0.2.\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	u.runsLock.Store(true)
	running := a.shown(t, func(r updateRead) bool { return r.Running && r.Offer != nil })
	if running.Outcome != "CYFR is being updated." {
		t.Fatalf("the page shows %+v while the lock is held", running)
	}
	read := func(within time.Duration) updateRead {
		t.Helper()
		ctx, cancel := context.WithTimeout(context.Background(), within)
		defer cancel()
		var got updateRead
		if w := a.readUpdate(ctx, a.ReadToken, running.Seq); w.Body.Len() == 0 || json.Unmarshal(w.Body.Bytes(), &got) != nil {
			t.Fatalf("the read answered %q", w.Body)
		}
		return got
	}
	// The read finds the lock held, so waits; the update lets it go.
	var asked atomic.Int32
	a.UpdateRuns = func(string) bool { return asked.Add(1) == 1 }
	if got := read(2 * time.Second); got.Running || got.Outcome != "Updated to release 0.0.2." || asked.Load() < 2 {
		t.Fatalf("with the lock let go while it waited, the read answered %+v, the locks asked %d times", got, asked.Load())
	}
	a.UpdateRuns = func(string) bool { return false }
	if got := read(100 * time.Millisecond); got.Running {
		t.Fatalf("begun with the lock let go, the read answered %+v", got)
	}
}

// The page and the yes ask the same locks: with this computer's own
// CYFR's change offered, the stack's lock of its folder, held by an
// update run at a terminal, shows the update running and no yes.
func TestThePageReadsTheLockTheYesAsks(t *testing.T) {
	dir := t.TempDir()
	a := newApp(t, t.TempDir(), offline())
	newUpdating(t, a, UpdatePlan{UpdateOffer: UpdateOffer{App: "0.0.2", Target: "0.0.2", Step: "stack"}, Dir: dir})
	a.UpdateRuns = func(project string) bool { return project == dir }
	if got := a.shown(t, offeredAs(1)); !got.Running {
		t.Fatalf("with its folder's lock held the page shows %+v", got)
	}
}

// A yes whose run cannot start leaves the last update's record as it was,
// its time too.
func TestAYesThatCannotStartKeepsTheLastRecord(t *testing.T) {
	a := newApp(t, t.TempDir(), offline())
	u := newUpdating(t, a, appPlan)
	u.refuse = errors.New("The update could not be started apart from this app (Access is denied.); nothing was changed. Run 'cyfr update' in a terminal instead")
	at := time.Date(2026, 11, 25, 12, 0, 0, 0, time.UTC)
	if err := os.WriteFile(a.UpdateRecord, []byte("The CYFR app is release 0.0.1.\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(a.UpdateRecord, at, at); err != nil {
		t.Fatal(err)
	}
	a.shown(t, offeredAs(1))
	a.StartUpdate(1)
	got := a.shown(t, func(r updateRead) bool { return r.Refused != "" })
	if got.Record != "The CYFR app is release 0.0.1.\n" || got.At != "2026-11-25 12:00 UTC" {
		t.Fatalf("a yes that started nothing left the record %q at %s", got.Record, got.At)
	}
}

// A yes while an update runs, by its locks, cyfr update's or the stack's
// of the CYFR the offer changes, starts nothing and leaves the record as
// it was: the page says why.
func TestAYesWhileAnUpdateRunsIsRefusedBeforeTheRecordIsTouched(t *testing.T) {
	for name, plan := range map[string]UpdatePlan{"app": appPlan, "stack": {UpdateOffer: UpdateOffer{App: "0.0.2", Target: "0.0.2", Step: "stack",
		Says: []string{"Updating it to release 0.0.2:"}}, Dir: "/home/ada/cyfr", Args: []string{"update", "--version", "0.0.2", "--confirmed", "c"}}} {
		t.Run(name, func(t *testing.T) {
			a := newApp(t, t.TempDir(), offline())
			u := newUpdating(t, a, plan)
			var asked []string
			a.UpdateRuns = func(project string) bool {
				asked = append(asked, project)
				return project == plan.Dir && name == "stack" || name == "app"
			}
			if err := os.WriteFile(a.UpdateRecord, []byte("the last update's\n"), 0o600); err != nil {
				t.Fatal(err)
			}
			offer := a.shown(t, func(r updateRead) bool { return r.Offer != nil }).Offer
			a.StartUpdate(offer.ID)
			if len(u.begun) != 0 {
				t.Fatal("a yes while an update runs started one")
			}
			if data, _ := os.ReadFile(a.UpdateRecord); string(data) != "the last update's\n" {
				t.Fatalf("the refused yes left the record %q", data)
			}
			if got := a.shown(t, func(r updateRead) bool { return r.Refused != "" }); !strings.HasPrefix(got.Refused, "Another update is changing CYFR on this computer") {
				t.Fatalf("the page shows %+v", got)
			}
			if name == "stack" && !slices.Contains(asked, plan.Dir) {
				t.Fatalf("the stack's lock was not asked: %q", asked)
			}
		})
	}
}
