// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package desktop

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/cyfr/codex/internal/account"
	"github.com/cyfr/codex/internal/disk"
	"github.com/cyfr/codex/internal/shell"
)

// app is a Service as the app's cyfr runs it, over a client record and a
// key record of its own, with the messages it sends main collected and
// the directory each CYFR names set by the test.
type app struct {
	*Service
	sent       chan Message
	discovered atomic.Int32
	directory  atomic.Value
}

func newApp(t *testing.T, dir string, client *http.Client) *app {
	t.Helper()
	a := &app{sent: make(chan Message, 16)}
	a.directory.Store(account.DefaultDirectory)
	a.Service = &Service{
		Token:       "the-run-token",
		Clients:     shell.ClientFile(filepath.Join(dir, "client.json")),
		Record:      filepath.Join(dir, "holder.json"),
		Client:      client,
		DisplayName: "laptop",
		Send:        func(m Message) error { a.sent <- m; return nil },
		Discover: func(_ context.Context, _ *http.Client, home string) (account.Discovered, error) {
			a.discovered.Add(1)
			d := a.directory.Load().(string)
			origin, _, _ := account.DirectoryOrigin(d)
			return account.Discovered{Directory: d, Origin: origin}, nil
		},
		Shell: func(c *shell.Config) {
			c.Chip = func() bool { return false }
			c.Detect = func(string) disk.Report { return disk.Report{Root: disk.Unknown, Data: disk.Unknown} }
		},
	}
	return a
}

// request is a request as the chooser's page sends it, changed by edit.
func (a *app) request(ctx context.Context, path string, body map[string]string, edit func(*http.Request)) *httptest.ResponseRecorder {
	if _, ok := body["token"]; !ok {
		body["token"] = a.Token
	}
	raw, _ := json.Marshal(body)
	r := httptest.NewRequestWithContext(ctx, http.MethodPost, "http://"+shell.Listen+path, strings.NewReader(string(raw)))
	r.Host = shell.Listen
	r.Header.Set("Origin", shell.Origin)
	r.Header.Set("Content-Type", "application/json")
	if edit != nil {
		edit(r)
	}
	w := httptest.NewRecorder()
	a.ServeHTTP(w, r)
	return w
}

func (a *app) post(t *testing.T, path string, body map[string]string) answer {
	t.Helper()
	w := a.request(context.Background(), path, body, nil)
	var got answer
	if w.Code != http.StatusOK || json.Unmarshal(w.Body.Bytes(), &got) != nil {
		t.Fatalf("%s answered %d %s", path, w.Code, w.Body)
	}
	return got
}

// connect posts path as a goroutine: a selection waits for main's
// home-ready.
func (a *app) connect(t *testing.T, path string, body map[string]string) <-chan answer {
	out := make(chan answer, 1)
	go func() { out <- a.post(t, path, body) }()
	return out
}

func (a *app) next(t *testing.T) Message {
	t.Helper()
	select {
	case m := <-a.sent:
		return m
	case <-time.After(5 * time.Second):
		t.Fatal("cyfr sent main nothing")
	}
	return Message{}
}

func (a *app) quiet(t *testing.T) {
	t.Helper()
	select {
	case m := <-a.sent:
		t.Fatalf("cyfr sent main %+v", m)
	default:
	}
}

func (a *app) get(path string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(http.MethodGet, "http://"+shell.Listen+path, nil)
	r.Host = shell.Listen
	w := httptest.NewRecorder()
	a.ServeHTTP(w, r)
	return w
}

// offline is a client that reaches nothing, as the device's pages read
// the account service.
func offline() *http.Client {
	return &http.Client{Transport: roundTrip(func(*http.Request) (*http.Response, error) {
		return nil, errors.New("offline")
	})}
}

type roundTrip func(*http.Request) (*http.Response, error)

func (f roundTrip) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func answered(t *testing.T, ch <-chan answer) answer {
	t.Helper()
	select {
	case a := <-ch:
		return a
	case <-time.After(5 * time.Second):
		t.Fatal("the chooser's request did not answer")
	}
	return answer{}
}

// Only the chooser's own page, carrying the run token main gave it, is
// answered; anything else reads no CYFR.
func TestTheChooserAnswersOnlyItsOwnPage(t *testing.T) {
	a := newApp(t, t.TempDir(), nil)
	for _, tc := range []struct {
		name string
		edit func(*http.Request)
		body map[string]string
		code int
	}{
		{"another token", nil, map[string]string{"token": "a-guess", "address": "cyfr.example.com"}, 403},
		{"no token", nil, map[string]string{"token": "", "address": "cyfr.example.com"}, 403},
		{"another origin", func(r *http.Request) { r.Header.Set("Origin", "https://evil.example") }, map[string]string{"address": "cyfr.example.com"}, 403},
		{"no origin", func(r *http.Request) { r.Header.Del("Origin") }, map[string]string{"address": "cyfr.example.com"}, 403},
		{"a rebinding name", func(r *http.Request) { r.Host = "evil.example:7340" }, map[string]string{"address": "cyfr.example.com"}, 421},
		{"a form", func(r *http.Request) { r.Header.Set("Content-Type", "application/x-www-form-urlencoded") }, map[string]string{"address": "cyfr.example.com"}, 415},
		{"an unknown field", nil, map[string]string{"address": "cyfr.example.com", "setup": "x"}, 400},
		{"a GET", func(r *http.Request) { r.Method = http.MethodGet }, map[string]string{"address": "cyfr.example.com"}, 404},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if w := a.request(context.Background(), "/bootstrap/connect", tc.body, tc.edit); w.Code != tc.code {
				t.Fatalf("answered %d, want %d: %s", w.Code, tc.code, w.Body)
			}
		})
	}
	if n := a.discovered.Load(); n != 0 {
		t.Fatalf("%d CYFRs were read", n)
	}
	a.quiet(t)
}

func TestTheChooserTakesOnlyAnHTTPSAddress(t *testing.T) {
	a := newApp(t, t.TempDir(), nil)
	for _, address := range []string{"http://cyfr.example.com", "https://cyfr.example.com/path", "https://user@cyfr.example.com", "", "ftp://x"} {
		if got := a.post(t, "/bootstrap/connect", map[string]string{"address": address}); got.Error == "" {
			t.Errorf("%q was taken: %+v", address, got)
		}
	}
	if n := a.discovered.Load(); n != 0 {
		t.Fatalf("%d CYFRs were read", n)
	}
}

// A CYFR whose directory is cyfr.run opens at once: main hears home, and
// only once main answers home-ready for that CYFR are the device's pages
// served.
func TestACYFROnTheDefaultDirectoryOpensOnceMainIsReady(t *testing.T) {
	dir := t.TempDir()
	a := newApp(t, dir, offline())
	if w := a.get("/"); w.Code != http.StatusSeeOther || w.Header().Get("Location") != "/bootstrap/" {
		t.Fatalf("before a CYFR is selected / answered %d %s", w.Code, w.Header().Get("Location"))
	}
	done := a.connect(t, "/bootstrap/connect", map[string]string{"address": " CYFR.example.com/ "})
	if m := a.next(t); m.Type != TypeHome || m.Home != "https://cyfr.example.com" || m.Account != account.DefaultDirectory || m.Proxy != "" {
		t.Fatalf("main heard %+v", m)
	}
	a.HomeReady("https://another.example.com")
	if w := a.get("/"); w.Code != http.StatusSeeOther {
		t.Fatal("the device's pages were served before main was ready")
	}
	a.HomeReady("https://cyfr.example.com")
	if got := answered(t, done); got.Next != "/" || got.Error != "" {
		t.Fatalf("answered %+v", got)
	}
	if w := a.get("/"); w.Code != http.StatusOK || !strings.Contains(w.Body.String(), "Set up CYFR") {
		t.Fatalf("the device's pages are not served: %d %s", w.Code, w.Body)
	}
	c, err := a.Clients.Load()
	if err != nil || c.Home != "https://cyfr.example.com" || c.Directory != account.DefaultDirectory || c.Project != "" {
		t.Fatalf("remembered %+v, %v", c, err)
	}
	if got := a.post(t, "/bootstrap/connect", map[string]string{"address": "another.example.com"}); got.Error == "" {
		t.Fatalf("a second CYFR was selected in one run: %+v", got)
	}
	a.quiet(t)
}

// main's home-ready for another CYFR opens nothing: the selection waits,
// and ends unopened when its request does.
func TestAHomeReadyForAnotherCYFROpensNothing(t *testing.T) {
	a := newApp(t, t.TempDir(), nil)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan *httptest.ResponseRecorder, 1)
	go func() {
		done <- a.request(ctx, "/bootstrap/connect", map[string]string{"address": "cyfr.example.com"}, nil)
	}()
	a.next(t)
	a.HomeReady("https://another.example.com")
	cancel()
	w := <-done
	var got answer
	_ = json.Unmarshal(w.Body.Bytes(), &got)
	if got.Next != "" || got.Error == "" {
		t.Fatalf("answered %+v", got)
	}
	if w := a.get("/"); w.Code != http.StatusSeeOther {
		t.Fatal("the device's pages were served")
	}
}

// Another directory than cyfr.run is shown whole and approved once before
// anything contacts it; a run that finds the one approved goes on at
// once, and a CYFR that names another asks again.
func TestAnotherDirectoryIsApprovedBeforeAnythingContactsIt(t *testing.T) {
	var contacted atomic.Int32
	service := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		contacted.Add(1)
		http.NotFound(w, r)
	}))
	defer service.Close()
	custom := service.URL + "/accounts"
	dir := t.TempDir()
	a := newApp(t, dir, service.Client())
	a.directory.Store(custom)

	got := a.post(t, "/bootstrap/connect", map[string]string{"address": "cyfr.example.com"})
	if got.Confirm != custom || got.Home != "https://cyfr.example.com" || got.Next != "" {
		t.Fatalf("answered %+v", got)
	}
	if got := a.post(t, "/bootstrap/approve", map[string]string{"home": "https://cyfr.example.com", "directory": "https://cyfr.run"}); got.Error == "" {
		t.Fatalf("another directory than the one shown was approved: %+v", got)
	}
	if got := a.post(t, "/bootstrap/approve", map[string]string{"home": "https://cyfr.example.com", "directory": custom}); got.Error == "" {
		t.Fatalf("an approval was taken twice: %+v", got)
	}
	a.quiet(t)
	if n := contacted.Load(); n != 0 {
		t.Fatalf("the account service was contacted %d times before its approval", n)
	}

	a.post(t, "/bootstrap/connect", map[string]string{"address": "cyfr.example.com"})
	done := a.connect(t, "/bootstrap/approve", map[string]string{"home": "https://cyfr.example.com", "directory": custom})
	if m := a.next(t); m.Type != TypeHome || m.Account != service.URL {
		t.Fatalf("main heard %+v", m)
	}
	a.HomeReady("https://cyfr.example.com")
	if got := answered(t, done); got.Next != "/" {
		t.Fatalf("answered %+v", got)
	}

	again := newApp(t, dir, service.Client())
	again.directory.Store(custom)
	done = again.connect(t, "/bootstrap/connect", map[string]string{"address": "cyfr.example.com"})
	if m := again.next(t); m.Type != TypeHome {
		t.Fatalf("the approved directory was asked about again: %+v", m)
	}
	again.HomeReady("https://cyfr.example.com")
	answered(t, done)

	moved := newApp(t, dir, service.Client())
	moved.directory.Store(service.URL + "/elsewhere")
	if got := moved.post(t, "/bootstrap/connect", map[string]string{"address": "cyfr.example.com"}); got.Confirm != service.URL+"/elsewhere" {
		t.Fatalf("a changed directory went on unapproved: %+v", got)
	}
	moved.quiet(t)
}

// Every end of main's messages locks the device and says so: lock,
// shutdown, the pipe's end, and a line that is not main's, which also
// ends the run with its refusal.
func TestEveryEndOfMainsMessagesLocks(t *testing.T) {
	for _, tc := range []struct {
		name, in string
		locks    int
		refused  bool
	}{
		{"lock, then the pipe's end", `{"version":1,"type":"lock"}` + "\n", 2, false},
		{"shutdown, unread after", `{"version":1,"type":"shutdown"}` + "\n" + `{"version":1,"type":"lock"}` + "\n", 1, false},
		{"a line that is not main's", `{"type":"lock"}` + "\n", 1, true},
		{"a line past the bound", strings.Repeat("x", MaxLine+2) + "\n", 1, true},
		{"a reply to no folder asked for", `{"version":1,"type":"folder-picked","id":"f1","path":null}` + "\n", 1, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			a := newApp(t, t.TempDir(), nil)
			err := a.Run(strings.NewReader(tc.in))
			if tc.refused != errors.Is(err, ErrRefused) {
				t.Fatalf("the run ended with %v", err)
			}
			for range tc.locks {
				if m := a.next(t); m.Type != TypeLocked {
					t.Fatalf("main heard %+v", m)
				}
			}
			a.quiet(t)
		})
	}
}

func TestTheChooserPageRunsOnlyItsOwnScript(t *testing.T) {
	a := newApp(t, t.TempDir(), nil)
	w := a.get("/bootstrap/")
	policy := w.Header().Get("Content-Security-Policy")
	if w.Code != http.StatusOK || !strings.Contains(policy, "script-src "+hash(bootstrapScript)+";") ||
		strings.Contains(policy, "unsafe") || !strings.Contains(policy, "frame-ancestors 'none'") ||
		!strings.Contains(w.Body.String(), "<script>"+bootstrapScript+"</script>") {
		t.Fatalf("served %d under %q", w.Code, policy)
	}
	if !strings.Contains(w.Body.String(), "Setting up CYFR on this computer comes in the next version of this app.") {
		t.Fatal("the chooser does not say where local setup is")
	}
}
