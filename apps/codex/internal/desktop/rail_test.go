// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package desktop

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"regexp"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/cyfr/codex/internal/account"
	"github.com/cyfr/codex/internal/shell"
)

// readRail is the rail's read of the list, seen the change it last
// showed, as its page sends it with token.
func (a *app) readRail(ctx context.Context, token string, seen uint64) *httptest.ResponseRecorder {
	raw, _ := json.Marshal(map[string]any{"token": token, "seen": seen})
	r := httptest.NewRequestWithContext(ctx, http.MethodPost, "http://"+shell.Listen+"/rail/list", strings.NewReader(string(raw)))
	r.Host = shell.Listen
	r.Header.Set("Origin", shell.Origin)
	r.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	a.ServeHTTP(w, r)
	return w
}

func (a *app) rail(t *testing.T, seen uint64) railList {
	t.Helper()
	w := a.readRail(context.Background(), a.ReadToken, seen)
	var got railList
	if w.Code != http.StatusOK || json.Unmarshal(w.Body.Bytes(), &got) != nil {
		t.Fatalf("the rail's read answered %d %s", w.Code, w.Body)
	}
	return got
}

// The rail's credential reads the list and nothing else: every request of
// the chooser's refuses it, however well formed, changing nothing and
// telling main nothing; and neither the rail's page, its address nor its
// read carries the run token.
func TestTheRailsReadTokenChangesNothing(t *testing.T) {
	a := newApp(t, t.TempDir(), offline())
	seed(t, a.Homes, "https://work.example.com", shell.ClientRecord{Directory: "https://cyfr.run/directory"})
	before := a.record(t)
	for path := range chooserRoutes {
		body := map[string]string{"token": a.ReadToken, "address": "https://other.example.com", "epoch": "0", "picks": "0", "run": "0"}
		if w := a.request(context.Background(), path, body, nil); w.Code != http.StatusForbidden {
			t.Errorf("%s with the rail's token answered %d %s", path, w.Code, w.Body)
		}
	}
	if got := a.record(t); got != before {
		t.Fatalf("the list became %s", got)
	}
	a.quiet(t)
	page := a.get("/rail/")
	if page.Code != http.StatusOK || strings.Contains(page.Body.String(), a.Token) {
		t.Fatalf("the rail's page answered %d, or carries the run token", page.Code)
	}
	if strings.Contains(a.RailURL(), a.Token) || !strings.HasSuffix(a.RailURL(), "#read="+a.ReadToken) {
		t.Fatalf("the rail's address is %s", a.RailURL())
	}
	if w := a.readRail(context.Background(), a.ReadToken, 0); w.Code != http.StatusOK || strings.Contains(w.Body.String(), a.Token) {
		t.Fatalf("the rail's read answered %d %s", w.Code, w.Body)
	}
	if w := a.readRail(context.Background(), a.Token, 0); w.Code != http.StatusForbidden {
		t.Fatalf("the rail's read took the run token: %d", w.Code)
	}
	if w := a.readRail(context.Background(), "", 0); w.Code != http.StatusForbidden {
		t.Fatalf("the rail's read took no token: %d", w.Code)
	}
}

// The rail's page as it is served, before any script of it runs, offers
// Set up on a desktop, and on a box's screen offers none: its first paint,
// before the list answers, shows nothing the box never offers.
func TestABoxsRailOffersNoSetUpBeforeItsListAnswers(t *testing.T) {
	setup := regexp.MustCompile(`<li( hidden)?><a class="way" id="setup"`)
	desktop := newApp(t, t.TempDir(), offline())
	if got := setup.FindStringSubmatch(desktop.get("/rail/").Body.String()); got == nil || got[1] != "" {
		t.Fatalf("a desktop's rail offers no Set up: %q", got)
	}
	box := newOnBox(t)
	if got := setup.FindStringSubmatch(box.get("/rail/").Body.String()); got == nil || got[1] != " hidden" {
		t.Fatalf("a box's rail offers Set up before its list answers: %q", got)
	}
}

// The rail's read answers the list at once when it has not seen this
// change, and otherwise waits for the next one.
func TestTheRailWaitsForTheListsNextChange(t *testing.T) {
	a := newApp(t, t.TempDir(), offline())
	seed(t, a.Homes, "https://work.example.com", shell.ClientRecord{Directory: "https://cyfr.run/directory"})
	first := a.rail(t, 0)
	if want := []RailCYFR{{Home: "https://work.example.com"}}; !reflect.DeepEqual(first.CYFRs, want) {
		t.Fatalf("the rail shows %+v", first.CYFRs)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()
	if w := a.readRail(ctx, a.ReadToken, first.Seq); w.Body.Len() != 0 {
		t.Fatalf("a read of the change seen answered at once: %s", w.Body)
	}
	got := make(chan railList, 1)
	go func() { got <- a.rail(t, first.Seq) }()
	a.Forget("https://work.example.com")
	select {
	case l := <-got:
		if want := []RailCYFR{{Home: "https://work.example.com", Forgetting: true}}; !reflect.DeepEqual(l.CYFRs, want) || l.Seq == first.Seq {
			t.Fatalf("the rail shows %+v at %d", l.CYFRs, l.Seq)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the rail did not hear the list change")
	}
}

// erases is what main is asked to erase next, n of them, by store.
func (a *app) erases(t *testing.T, n int) map[string]uint64 {
	t.Helper()
	out := map[string]uint64{}
	for range n {
		m := a.next(t)
		if m.Type != TypeErase {
			t.Fatalf("main heard %+v, not an erase", m)
		}
		out[m.Home+" "+m.Account] = m.ID
	}
	a.quiet(t)
	return out
}

func held(t *testing.T, f shell.Homes, home string) (shell.ClientRecord, bool) {
	t.Helper()
	l, err := f.Load()
	if err != nil {
		t.Fatal(err)
	}
	rec, ok := l.Homes[home]
	return rec, ok
}

// A row the rail showed before its Forget ended, pressed after, adds
// nothing: a press of a CYFR this computer keeps is answered with a
// sentence, asks the CYFR nothing and lists it no more; Connect is the one
// way to add it again.
func TestAPressOfARowForgottenMeanwhileAddsNothing(t *testing.T) {
	const home = "https://work.example.com"
	a := newApp(t, t.TempDir(), offline())
	seed(t, a.Homes, home, shell.ClientRecord{Directory: account.DefaultDirectory})
	a.Forget(home)
	for _, id := range a.erases(t, 1) {
		a.Erased(id, true)
	}
	a.quiet(t)
	if _, ok := held(t, a.Homes, home); ok {
		t.Fatal("the CYFR is still listed")
	}
	asked := a.discovered.Load()
	got := a.post(t, "/bootstrap/connect", map[string]string{"address": home, "kept": "true"})
	if !strings.Contains(got.Error, "no longer keeps "+home) {
		t.Fatalf("the press answered %+v", got)
	}
	a.quiet(t)
	if _, ok := held(t, a.Homes, home); ok || a.discovered.Load() != asked {
		t.Fatalf("the press added the CYFR (%v) or asked it (%d)", ok, a.discovered.Load()-asked)
	}
}

// Forget marks the CYFR being forgotten, so nothing opens or adds it, asks
// main to erase its content and each account service's ceremony storage
// it recorded, and removes it once every erase succeeded; a late or
// repeated answer changes nothing.
func TestForgetErasesEveryStoreThenRemovesTheCYFR(t *testing.T) {
	const home, ceremony = "https://work.example.com", "https://cyfr.run"
	a := newApp(t, t.TempDir(), offline())
	seed(t, a.Homes, home, shell.ClientRecord{Directory: "https://cyfr.run/directory", Ceremonies: []string{ceremony}})
	a.Forget(home)
	ids := a.erases(t, 2)
	if _, ok := ids[home+" "]; !ok {
		t.Fatalf("its content was not asked to be erased: %v", ids)
	}
	if _, ok := ids[home+" "+ceremony]; !ok {
		t.Fatalf("its ceremony's storage was not asked to be erased: %v", ids)
	}
	if last, _ := a.last(t); last != "" {
		t.Fatalf("%s is still the CYFR selected last", last)
	}
	if _, err := a.Homes.Select(home, "https://cyfr.run/directory", true, shell.Typed); err == nil {
		t.Fatal("a CYFR being forgotten was selected")
	}
	if got := a.post(t, "/bootstrap/connect", map[string]string{"address": home}); got.Error == "" {
		t.Fatalf("a CYFR being forgotten was connected to: %+v", got)
	}
	a.quiet(t)
	a.Erased(ids[home+" "], true)
	a.Erased(ids[home+" "], true)
	if rec, ok := held(t, a.Homes, home); !ok || !rec.Forgetting {
		t.Fatalf("the CYFR went before its every store was erased: %+v %v", rec, ok)
	}
	a.Erased(ids[home+" "+ceremony], true)
	if _, ok := held(t, a.Homes, home); ok {
		t.Fatal("the CYFR is still listed once every store was erased")
	}
	before := a.record(t)
	a.Erased(ids[home+" "+ceremony], true)
	a.Erased(99, false)
	if a.record(t) != before || len(a.rail(t, 0).CYFRs) != 0 {
		t.Fatal("a late erased changed the list")
	}
	a.quiet(t)
}

// An erase that failed keeps the CYFR listed and unopenable, shown as not
// forgotten; Forget again asks for every erase again, and removes it once
// they succeed.
func TestAFailedEraseKeepsTheCYFRUntilForgetSucceeds(t *testing.T) {
	const home = "https://work.example.com"
	a := newApp(t, t.TempDir(), offline())
	seed(t, a.Homes, home, shell.ClientRecord{Directory: "https://cyfr.run/directory", Ceremonies: []string{"https://cyfr.run"}})
	a.Forget(home)
	ids := a.erases(t, 2)
	a.Erased(ids[home+" "], false)
	a.Erased(ids[home+" https://cyfr.run"], true)
	if rec, ok := held(t, a.Homes, home); !ok || !rec.Forgetting {
		t.Fatalf("a CYFR whose erase failed is %+v %v", rec, ok)
	}
	if want := []RailCYFR{{Home: home, Forgetting: true, Failed: true}}; !reflect.DeepEqual(a.rail(t, 0).CYFRs, want) {
		t.Fatalf("the rail shows %+v", a.rail(t, 0).CYFRs)
	}
	a.Forget(home)
	again := a.erases(t, 2)
	a.Erased(ids[home+" "], true)
	if _, ok := held(t, a.Homes, home); !ok {
		t.Fatal("an erase of the failed Forget's answered the retry")
	}
	for _, id := range again {
		a.Erased(id, true)
	}
	if _, ok := held(t, a.Homes, home); ok {
		t.Fatal("the CYFR is still listed once its retry erased every store")
	}
}

// The open CYFR is not forgotten: main leaves it first.
func TestTheOpenCYFRIsNotForgotten(t *testing.T) {
	const home = "https://work.example.com"
	a := newApp(t, t.TempDir(), offline())
	seed(t, a.Homes, home, shell.ClientRecord{Directory: "https://cyfr.run/directory"})
	a.mu.Lock()
	a.pages, a.committed = &shell.Server{}, Message{Type: TypeHome, Home: home}
	a.mu.Unlock()
	before := a.record(t)
	a.Forget(home)
	a.quiet(t)
	if a.record(t) != before {
		t.Fatal("the open CYFR was marked being forgotten")
	}
}

// A Forget the app did not finish, ended before every erase was answered,
// is resumed when cyfr next runs, before any message of main's is read:
// the CYFR stays unopenable meanwhile and goes once its erases succeed.
func TestAnInterruptedForgetIsResumedAtTheNextRun(t *testing.T) {
	const home = "https://work.example.com"
	dir := t.TempDir()
	first := newApp(t, dir, offline())
	seed(t, first.Homes, "https://other.example.com", shell.ClientRecord{Directory: "https://cyfr.run/directory"})
	seed(t, first.Homes, home, shell.ClientRecord{Directory: "https://cyfr.run/directory", Ceremonies: []string{"https://cyfr.run"}})
	first.Forget(home)
	first.erases(t, 2)
	first.End()

	next := newApp(t, dir, offline())
	in, out := io.Pipe()
	ran := make(chan error, 1)
	go func() { ran <- next.Run(in) }()
	ids := next.erases(t, 2)
	if rec, ok := held(t, next.Homes, home); !ok || !rec.Forgetting {
		t.Fatalf("the CYFR being forgotten is %+v %v", rec, ok)
	}
	keys := []string{}
	for k, id := range ids {
		keys = append(keys, k)
		fmt.Fprintf(out, `{"version":%d,"type":"erased","id":%d,"ok":true}`+"\n", Version, id)
	}
	slices.Sort(keys)
	if want := []string{home + " ", home + " https://cyfr.run"}; !slices.Equal(keys, want) {
		t.Fatalf("the resumed Forget erases %v", keys)
	}
	fmt.Fprintf(out, `{"version":%d,"type":"shutdown"}`+"\n", Version)
	select {
	case err := <-ran:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("cyfr did not end")
	}
	if _, ok := held(t, next.Homes, home); ok {
		t.Fatal("the resumed Forget left the CYFR listed")
	}
	if _, ok := held(t, next.Homes, "https://other.example.com"); !ok {
		t.Fatal("Forget took another CYFR with it")
	}
}

// A press of a row whose CYFR names a changed account service asks the
// person to approve it; the rail is free meanwhile, so the person can
// Forget that row before pressing Approve. The approval updates the row it
// began from, and finds none: it adds nothing.
func TestAnApprovalBegunFromARowForgottenMeanwhileAddsNothing(t *testing.T) {
	const home = "https://work.example.com"
	const changed = "https://account.example.com/directory"
	a := newApp(t, t.TempDir(), offline())
	seed(t, a.Homes, home, shell.ClientRecord{Directory: account.DefaultDirectory})
	a.directory.Store(changed)
	asked := a.post(t, "/bootstrap/connect", map[string]string{"address": home, "kept": "true"})
	if asked.Confirm != changed {
		t.Fatalf("kept press answered %+v, wanted approval for %s", asked, changed)
	}
	a.Forget(home)
	for _, id := range a.erases(t, 1) {
		a.Erased(id, true)
	}
	if _, ok := held(t, a.Homes, home); ok {
		t.Fatal("Forget did not remove the row")
	}
	approval := a.connect(t, "/bootstrap/approve", map[string]string{"cyfr": home, "directory": changed})
	select {
	case m := <-a.sent:
		if m.Type != TypeHome || m.Home != home {
			t.Fatalf("unexpected message %+v", m)
		}
		a.ready(home)
		a.opened(t, home)
		got := answered(t, approval)
		if _, ok := held(t, a.Homes, home); ok {
			t.Fatalf("approval from the kept press added the forgotten CYFR again: %+v", got)
		}
	case got := <-approval:
		if got.Error == "" {
			t.Fatalf("approval answered %+v", got)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("approval neither proposed nor answered")
	}
}

// A press of a folder's row whose Forget ends while the folder is asked
// whether its CYFR answers adds the folder's CYFR again on no road.
func TestAFolderPressForgottenDuringItsCheckAddsNothing(t *testing.T) {
	const home = "http://localhost:4100"
	a := newApp(t, t.TempDir(), offline())
	seed(t, a.Homes, home, shell.ClientRecord{Project: localFolder})
	a.Local = func(string) (Local, error) {
		return Local{
			Shell: shell.Config{Address: home, Client: offline(), Directory: account.DefaultDirectory},
			Answers: func(context.Context) error {
				rec, held, err := a.Homes.Forgetting(home)
				if err != nil {
					return err
				}
				if held {
					return a.Homes.Forgotten(home, rec.Generation)
				}
				return nil
			},
		}, nil
	}
	done := a.connect(t, "/bootstrap/connect", map[string]string{"address": home, "kept": "true"})
	select {
	case m := <-a.sent:
		if m.Type != TypeHome || m.Home != home {
			t.Fatalf("unexpected message %+v", m)
		}
		a.ready(home)
		a.opened(t, home)
		got := answered(t, done)
		if _, ok := held(t, a.Homes, home); ok {
			t.Fatalf("the kept press put the forgotten folder back on the rail: %+v", got)
		}
	case got := <-done:
		if got.Error == "" {
			t.Fatalf("the kept press answered %+v", got)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the kept press neither proposed nor answered")
	}
}

// A press of a folder's row is answered from the one reading of the list
// that began it: a folder Forget removed after that reading is opened from
// what the reading held, and its commit refused, never taken for a CYFR
// elsewhere at the saved address; one removed before it is refused at
// once. Neither asks any server.
func TestAForgottenFolderPressAsksNoServer(t *testing.T) {
	const home = "https://folder.example.test"
	answering := func(string) (Local, error) {
		return Local{Shell: shell.Config{Address: home, Client: offline(), Directory: account.DefaultDirectory},
			Answers: func(context.Context) error { return nil }}, nil
	}
	forget := func(a *app) {
		a.Forget(home)
		for _, id := range a.erases(t, 1) {
			a.Erased(id, true)
		}
		if _, ok := held(t, a.Homes, home); ok {
			t.Fatal("Forget did not remove the row")
		}
	}

	a := newApp(t, t.TempDir(), offline())
	seed(t, a.Homes, home, shell.ClientRecord{Project: localFolder})
	a.Local = answering
	pressed, rec, err := a.Homes.Row(home)
	if err != nil {
		t.Fatal(err)
	}
	forget(a)
	if got := a.folderRow(t.Context(), 0, home, rec.Project, pressed); got.Error == "" {
		t.Fatalf("the forgotten folder's press answered %+v", got)
	}
	if _, ok := held(t, a.Homes, home); ok || a.discovered.Load() != 0 {
		t.Fatalf("the press put the row back (%v) or asked %d servers", ok, a.discovered.Load())
	}

	b := newApp(t, t.TempDir(), offline())
	seed(t, b.Homes, home, shell.ClientRecord{Project: localFolder})
	b.Local = answering
	forget(b)
	if got := b.post(t, "/bootstrap/connect", map[string]string{"address": home, "kept": "true"}); got.Error == "" || b.discovered.Load() != 0 {
		t.Fatalf("a press of the row Forget removed answered %+v and asked %d servers", got, b.discovered.Load())
	}
	a.quiet(t)
	b.quiet(t)
}
