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
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/cyfr/codex/internal/account"
	"github.com/cyfr/codex/internal/shell"
	"github.com/cyfr/codex/internal/version"
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
	Dir: "/the/device", Args: []string{"update", "--version", "0.0.2"}, Header: "Updating the CYFR app to release 0.0.2, as asked in the app at 2026-11-25 12:00 UTC."}

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
// anew, its header first, for this account alone. Once the run ends the
// offer is dropped, and the next is worked out.
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
		Says: appPlan.Says}, Dir: appPlan.Dir, Args: appPlan.Args, Header: appPlan.Header}) {
		t.Fatalf("started %+v", u.begun)
	}
	if u.records[0] != a.UpdateRecord {
		t.Fatalf("the run's output is %s", u.records[0])
	}
	data, err := os.ReadFile(a.UpdateRecord)
	if err != nil || string(data) != appPlan.Header+"\n" {
		t.Fatalf("the record holds %q (%v)", data, err)
	}
	if info, _ := os.Stat(a.UpdateRecord); runtime.GOOS != "windows" && info.Mode().Perm() != 0o600 {
		t.Fatalf("the record's mode is %v", info.Mode())
	}
	if got := a.shown(t, func(r updateRead) bool { return r.Running }); got.Outcome != "CYFR is being updated." {
		t.Fatalf("the page shows %+v while it runs", got)
	}
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

// A record waiting is said at ready; the page shows it once, summed up,
// and the window's close removes it. One the page never showed, and one
// whose update still runs, stays.
func TestARecordIsShownOnceAndRemovedAsItsWindowCloses(t *testing.T) {
	a := newApp(t, t.TempDir(), offline())
	u := newUpdating(t, a, appPlan)
	header := AppHeader(version.Version, time.Date(2026, 11, 25, 12, 0, 0, 0, time.UTC))
	write := func(text string) {
		t.Helper()
		if err := os.WriteFile(a.UpdateRecord, []byte(text), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	write(header + "\nUpdating the CYFR app from 0.0.1 to " + version.Version + "...\n")
	if !a.RecordWaits() {
		t.Fatal("a record waiting is not said")
	}
	a.UpdateClosed()
	if !a.RecordWaits() {
		t.Fatal("a record the page never showed was removed")
	}
	got := a.shown(t, func(r updateRead) bool { return r.Record != "" })
	if got.Outcome != "The CYFR app is release "+version.Version+"." || !strings.HasPrefix(got.Record, header) {
		t.Fatalf("the page shows %+v", got)
	}
	u.runsLock.Store(true)
	a.UpdateClosed()
	if !a.RecordWaits() {
		t.Fatal("the record of an update that still runs was removed")
	}
	u.runsLock.Store(false)
	a.shown(t, func(r updateRead) bool { return r.Record != "" })
	a.UpdateClosed()
	if a.RecordWaits() {
		t.Fatal("the record shown stays after its window closed")
	}

	for record, want := range map[string]string{
		header + "\nError: The CYFR app of release 0.0.3 did not verify (x); nothing was changed and CYFR runs as it did\n": "The CYFR app of release 0.0.3 did not verify (x); nothing was changed and CYFR runs as it did",
		AppHeader("9.9.9", time.Now()) + "\n":                                                "The update ended without saying how; what it said is below.",
		StackHeader("/home/ada/cyfr", "0.0.2", time.Now()) + "\nUpdated to release 0.0.2.\n": "Your CYFR in /home/ada/cyfr is release 0.0.2.",
	} {
		if got := outcome(record, false); got != want {
			t.Errorf("%q is summed up as %q", record, got)
		}
		if got := outcome(record, true); got != "CYFR is being updated." {
			t.Errorf("a running %q is summed up as %q", record, got)
		}
	}
	if got := recordProject(StackHeader("/home/ada/my cyfr", "0.0.2", time.Now()) + "\n"); got != "/home/ada/my cyfr" {
		t.Fatalf("the stack's record names %q", got)
	}
}
