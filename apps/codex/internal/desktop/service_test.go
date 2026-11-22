// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package desktop

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/cyfr/codex/internal/account"
	"github.com/cyfr/codex/internal/account/accounttest"
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

// opened is cyfr telling main it committed home, which it says once a
// selection opened and never before.
func (a *app) opened(t *testing.T, home string) {
	t.Helper()
	if m := a.next(t); m.Type != TypeOpened || m.Home != home {
		t.Fatalf("main heard %+v, not that %s opened", m, home)
	}
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
	a.opened(t, "https://cyfr.example.com")
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
	a.opened(t, "https://cyfr.example.com")

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

	// Declined: the CYFR named another account service, which ended the
	// approval of the first; naming the first again asks again.
	back := newApp(t, dir, service.Client())
	back.directory.Store(custom)
	if got := back.post(t, "/bootstrap/connect", map[string]string{"address": "cyfr.example.com"}); got.Confirm != custom {
		t.Fatalf("a return to the account service approved before went on unasked: %+v", got)
	}
	back.quiet(t)
}

// A failed or unfinished selection leaves the account's record as it
// was: the device's screen keeps its working client until another CYFR
// admits this device.
func TestASelectionThatDidNotSucceedLeavesTheRecord(t *testing.T) {
	dir := t.TempDir()
	working := shell.ClientRecord{Project: "/home/ada/cyfr", ClientID: "pcl_box", Certificate: json.RawMessage(`{"box":1}`)}
	if err := shell.ClientFile(filepath.Join(dir, "client.json")).Save(working); err != nil {
		t.Fatal(err)
	}
	before, _ := os.ReadFile(filepath.Join(dir, "client.json"))
	unchanged := func(when string) {
		t.Helper()
		if after, _ := os.ReadFile(filepath.Join(dir, "client.json")); string(after) != string(before) {
			t.Fatalf("%s the record became %s", when, after)
		}
	}

	cancelled := newApp(t, dir, offline())
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan *httptest.ResponseRecorder, 1)
	go func() {
		done <- cancelled.request(ctx, "/bootstrap/connect", map[string]string{"address": "cyfr.example.com"}, nil)
	}()
	cancelled.next(t)
	cancel()
	<-done
	unchanged("after a selection cancelled before main was ready,")

	opened := newApp(t, dir, offline())
	answer := opened.connect(t, "/bootstrap/connect", map[string]string{"address": "cyfr.example.com"})
	opened.next(t)
	opened.HomeReady("https://cyfr.example.com")
	if got := answered(t, answer); got.Next != "/" {
		t.Fatalf("answered %+v", got)
	}
	unchanged("after a selection opened but never admitted,")
}

// A lock while the app waits for main's home-ready ends that selection:
// a home-ready after it opens nothing.
func TestALockEndsASelectionWaitingForMain(t *testing.T) {
	a := newApp(t, t.TempDir(), offline())
	done := a.connect(t, "/bootstrap/connect", map[string]string{"address": "cyfr.example.com"})
	a.next(t)
	a.Lock("Locked.")
	if m := a.next(t); m.Type != TypeLocked {
		t.Fatalf("main heard %+v", m)
	}
	a.HomeReady("https://cyfr.example.com")
	if got := answered(t, done); got.Next != "" || got.Error == "" {
		t.Fatalf("a locked selection answered %+v", got)
	}
	if w := a.get("/"); w.Code != http.StatusSeeOther {
		t.Fatal("the device's pages were served after the lock")
	}
	// main keeps no CYFR from this Connect: cyfr never said it opened one,
	// and proposes again for the next.
	a.quiet(t)
	again := a.connect(t, "/bootstrap/connect", map[string]string{"address": "cyfr.example.com"})
	if m := a.next(t); m.Type != TypeHome {
		t.Fatalf("the next Connect proposed nothing: %+v", m)
	}
	a.HomeReady("https://cyfr.example.com")
	answered(t, again)
	a.opened(t, "https://cyfr.example.com")
}

var (
	proofShape = regexp.MustCompile(`data-proof="([^"]+)"`)
	codeShape  = regexp.MustCompile(`<p class="code">([^<]+)</p>`)
)

// form posts a form of the device's own pages, as their script sends it.
func (a *app) form(path string, fields url.Values) *httptest.ResponseRecorder {
	r := httptest.NewRequest(http.MethodPost, "http://"+shell.Listen+path, strings.NewReader(fields.Encode()))
	r.Host = shell.Listen
	r.Header.Set("Origin", shell.Origin)
	r.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	w := httptest.NewRecorder()
	a.ServeHTTP(w, r)
	return w
}

// A lock at the recovery-code page, before the device's first connection,
// erases the key that setup holds and the page's proof: the code no longer
// shows to the page that holds the proof.
func TestALockBeforeTheFirstConnectionErasesTheKeyAndTheProof(t *testing.T) {
	accounts := accounttest.New(t)
	a := newApp(t, t.TempDir(), nil)
	a.directory.Store(accounts.URL())
	if got := a.post(t, "/bootstrap/connect", map[string]string{"address": "cyfr.example.com"}); got.Confirm != accounts.URL() {
		t.Fatalf("answered %+v", got)
	}
	done := a.connect(t, "/bootstrap/approve", map[string]string{"home": "https://cyfr.example.com", "directory": accounts.URL()})
	a.next(t)
	a.HomeReady("https://cyfr.example.com")
	answered(t, done)
	a.opened(t, "https://cyfr.example.com")

	drawn := codeShape.FindStringSubmatch(a.form("/passphrase", nil).Body.String())
	if drawn == nil {
		t.Fatal("no passphrase was drawn")
	}
	setup := a.form("/setup", url.Values{"name": {"alice"}, "secret": {drawn[1]}, "again": {drawn[1]}}).Body.String()
	proof, code := proofShape.FindStringSubmatch(setup), codeShape.FindStringSubmatch(setup)
	if proof == nil || code == nil {
		t.Fatalf("setup did not reach the recovery code:\n%s", setup)
	}
	if !strings.Contains(a.form("/recovery", url.Values{"proof": {proof[1]}}).Body.String(), code[1]) {
		t.Fatal("the page holding the proof is shown no recovery code before the lock")
	}
	a.Lock("Locked.")
	if m := a.next(t); m.Type != TypeLocked {
		t.Fatalf("main heard %+v", m)
	}
	if page := a.form("/recovery", url.Values{"proof": {proof[1]}}).Body.String(); strings.Contains(page, code[1]) {
		t.Fatalf("the proof still shows the recovery code after the lock:\n%s", page)
	}
}

// Every end of main's messages locks the device and says none of it:
// shutdown, the pipe's end and a line that is not main's, which also ends
// the run with its refusal. Only main's lock is answered locked. That an
// end locked shows in the selection it ended.
func TestEveryEndOfMainsMessagesLocksAndSaysNoLock(t *testing.T) {
	for _, tc := range []struct {
		name, in string
		said     int
		refused  bool
	}{
		{"lock, then the pipe's end", `{"version":1,"type":"lock"}` + "\n", 1, false},
		{"shutdown, unread after", `{"version":1,"type":"shutdown"}` + "\n" + `{"version":1,"type":"lock"}` + "\n", 0, false},
		{"a line that is not main's", `{"type":"lock"}` + "\n", 0, true},
		{"a line past the bound", strings.Repeat("x", MaxLine+2) + "\n", 0, true},
		{"a reply to no folder asked for", `{"version":1,"type":"folder-picked","id":"f1","path":null}` + "\n", 0, false},
		{"the pipe's end alone", "", 0, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			a := newApp(t, t.TempDir(), offline())
			selecting := a.connect(t, "/bootstrap/connect", map[string]string{"address": "cyfr.example.com"})
			if m := a.next(t); m.Type != TypeHome {
				t.Fatalf("main heard %+v", m)
			}
			err := a.Run(strings.NewReader(tc.in))
			if tc.refused != errors.Is(err, ErrRefused) {
				t.Fatalf("the run ended with %v", err)
			}
			if got := answered(t, selecting); got.Error != lockedSentence {
				t.Fatalf("the end did not lock: the selection answered %+v", got)
			}
			for range tc.said {
				if m := a.next(t); m.Type != TypeLocked {
					t.Fatalf("main heard %+v", m)
				}
			}
			a.quiet(t)
		})
	}
}

// The chooser's page runs its one script and style, each by its hash.
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

// One rule for a lock: nothing a request began before it publishes
// anything after it. A Connect still reading the CYFR's sign-in page when
// the lock is acknowledged sends main nothing more, and a home-ready after
// it opens nothing.
func TestALockDuringDiscoveryEndsTheConnect(t *testing.T) {
	a := newApp(t, t.TempDir(), offline())
	reading, release := make(chan struct{}), make(chan struct{})
	discover := a.Discover
	a.Discover = func(ctx context.Context, c *http.Client, home string) (account.Discovered, error) {
		close(reading)
		<-release
		return discover(ctx, c, home)
	}
	done := a.connect(t, "/bootstrap/connect", map[string]string{"address": "cyfr.example.com"})
	<-reading
	a.Lock("Locked.")
	if m := a.next(t); m.Type != TypeLocked {
		t.Fatalf("main heard %+v", m)
	}
	close(release)
	if got := answered(t, done); got.Next != "" || got.Error == "" {
		t.Fatalf("a Connect begun before the lock answered %+v", got)
	}
	a.HomeReady("https://cyfr.example.com")
	a.quiet(t)
	if w := a.get("/"); w.Code != http.StatusSeeOther {
		t.Fatal("the device's pages were served after the lock")
	}
}

// An approval stands only while the CYFR names the address approved: one
// that names cyfr.run, even in a Connect that never opened, ends it, and
// naming the first address again asks again.
func TestAnApprovalEndsWhenTheCYFRNamesTheDefault(t *testing.T) {
	dir := t.TempDir()
	custom := "https://accounts.example.com"
	first := newApp(t, dir, offline())
	first.directory.Store(custom)
	first.post(t, "/bootstrap/connect", map[string]string{"address": "cyfr.example.com"})
	done := first.connect(t, "/bootstrap/approve", map[string]string{"home": "https://cyfr.example.com", "directory": custom})
	first.next(t)
	first.HomeReady("https://cyfr.example.com")
	answered(t, done)

	moved := newApp(t, dir, offline())
	ctx, cancel := context.WithCancel(context.Background())
	cancelled := make(chan *httptest.ResponseRecorder, 1)
	go func() {
		cancelled <- moved.request(ctx, "/bootstrap/connect", map[string]string{"address": "cyfr.example.com"}, nil)
	}()
	moved.next(t)
	cancel()
	<-cancelled

	back := newApp(t, dir, offline())
	back.directory.Store(custom)
	if got := back.post(t, "/bootstrap/connect", map[string]string{"address": "cyfr.example.com"}); got.Confirm != custom {
		t.Fatalf("a return to the address approved before went on unasked: %+v", got)
	}
	back.quiet(t)
}

// signalling is a request body that says when the handler first reads it.
type signalling struct {
	io.Reader
	once    sync.Once
	reading chan struct{}
}

func (b *signalling) Read(p []byte) (int, error) {
	b.once.Do(func() { close(b.reading) })
	return b.Reader.Read(p)
}

// A request belongs to the lock time it arrived in, taken before its body
// is read: a Connect whose body is still arriving when the lock lands
// publishes nothing after it.
func TestAConnectStillArrivingWhenTheLockLandsPublishesNothing(t *testing.T) {
	a := newApp(t, t.TempDir(), offline())
	pr, pw := io.Pipe()
	body := &signalling{Reader: pr, reading: make(chan struct{})}
	r := httptest.NewRequest(http.MethodPost, "http://"+shell.Listen+"/bootstrap/connect", body)
	r.Host = shell.Listen
	r.Header.Set("Origin", shell.Origin)
	r.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	served := make(chan struct{})
	go func() { a.ServeHTTP(w, r); close(served) }()
	<-body.reading
	a.Lock("Locked.")
	if m := a.next(t); m.Type != TypeLocked {
		t.Fatalf("main heard %+v", m)
	}
	_, _ = io.WriteString(pw, `{"token":"the-run-token","address":"cyfr.example.com"}`)
	pw.Close()
	<-served
	var got answer
	_ = json.Unmarshal(w.Body.Bytes(), &got)
	if got.Error != lockedSentence {
		t.Fatalf("a Connect that arrived before the lock answered %+v", got)
	}
	a.HomeReady("https://cyfr.example.com")
	a.quiet(t)
	if n := a.discovered.Load(); n != 0 {
		t.Fatalf("it read %d CYFRs", n)
	}
}

// The chooser is one page: while one Connect is in flight a second is
// refused, in words the page shows, and the first goes on unharmed.
func TestASecondConnectWhileOneIsInFlightIsRefused(t *testing.T) {
	a := newApp(t, t.TempDir(), offline())
	first := a.connect(t, "/bootstrap/connect", map[string]string{"address": "cyfr.example.com"})
	if m := a.next(t); m.Type != TypeHome {
		t.Fatalf("main heard %+v", m)
	}
	if got := a.post(t, "/bootstrap/connect", map[string]string{"address": "another.example.com"}); got.Error != busySentence {
		t.Fatalf("a second Connect answered %+v", got)
	}
	a.quiet(t)
	a.HomeReady("https://cyfr.example.com")
	if got := answered(t, first); got.Next != "/" {
		t.Fatalf("the first Connect answered %+v", got)
	}
}

// Every exit of a Connect leaves the service able to take the next: one
// whose CYFR main got ready for but that could not be remembered ends
// unopened, and the next Connect goes on.
func TestAConnectThatFailsAfterHomeReadyLeavesTheServiceFree(t *testing.T) {
	dir := t.TempDir()
	record := filepath.Join(dir, "client.json")
	a := newApp(t, dir, offline())
	done := a.connect(t, "/bootstrap/connect", map[string]string{"address": "cyfr.example.com"})
	a.next(t)
	if err := os.Mkdir(record, 0o700); err != nil {
		t.Fatal(err)
	}
	a.HomeReady("https://cyfr.example.com")
	if got := answered(t, done); got.Next != "" || got.Error == "" {
		t.Fatalf("a Connect that could not remember its CYFR answered %+v", got)
	}
	if err := os.Remove(record); err != nil {
		t.Fatal(err)
	}
	again := a.connect(t, "/bootstrap/connect", map[string]string{"address": "cyfr.example.com"})
	if m := a.next(t); m.Type != TypeHome {
		t.Fatalf("the next Connect did not go on: %+v", m)
	}
	a.HomeReady("https://cyfr.example.com")
	if got := answered(t, again); got.Next != "/" {
		t.Fatalf("the next Connect answered %+v", got)
	}
	a.opened(t, "https://cyfr.example.com")
}

// An open CYFR's answer offers the device's pages, and so does the chooser
// shown again after a lock, whichever road the app offers: cyfr is not
// told the road, and names no address of that CYFR to load.
func TestAnOpenCYFRAnswersEveryChooserAlike(t *testing.T) {
	a := newApp(t, t.TempDir(), offline())
	done := a.connect(t, "/bootstrap/connect", map[string]string{"address": "cyfr.example.com"})
	a.next(t)
	a.HomeReady("https://cyfr.example.com")
	want := answer{Home: "https://cyfr.example.com", Next: "/"}
	if got := answered(t, done); got != want {
		t.Fatalf("answered %+v", got)
	}
	a.opened(t, "https://cyfr.example.com")
	a.Lock("")
	a.next(t)
	if got := a.post(t, "/bootstrap/state", map[string]string{}); got != want {
		t.Fatalf("the chooser after a lock shows %+v", got)
	}
}

// At launch the chooser is given the CYFR remembered, which on the passkey
// road it connects by itself, once a run: after any Connect began it is
// given none.
func TestARememberedCYFRResumesOnce(t *testing.T) {
	dir := t.TempDir()
	record := shell.ClientFile(filepath.Join(dir, "client.json"))
	if err := record.Save(shell.ClientRecord{Home: "https://cyfr.example.com", Directory: account.DefaultDirectory}); err != nil {
		t.Fatal(err)
	}
	a := newApp(t, dir, offline())
	if got := a.post(t, "/bootstrap/state", map[string]string{}); got.Resume != "https://cyfr.example.com" || got.Home != "https://cyfr.example.com" {
		t.Fatalf("the chooser shows %+v", got)
	}
	a.Discover = func(context.Context, *http.Client, string) (account.Discovered, error) {
		return account.Discovered{}, errors.New("unreachable")
	}
	if got := a.post(t, "/bootstrap/connect", map[string]string{"address": "cyfr.example.com"}); got.Error == "" {
		t.Fatalf("an unreachable CYFR answered %+v", got)
	}
	if got := a.post(t, "/bootstrap/state", map[string]string{}); got.Resume != "" || got.Home != "https://cyfr.example.com" {
		t.Fatalf("a Connect that failed is tried again by itself: %+v", got)
	}
}

// Main's leave (Connect to another CYFR, sent once main cleared what it
// kept) lets go of the CYFR open, locked and named in no locked, for a
// Connect to the next, which is then the one remembered. No page of cyfr's
// can do it.
func TestConnectToAnotherLeavesTheCYFROpen(t *testing.T) {
	const first, second = "https://cyfr.example.com", "https://bob.example.com"
	open := func(a *app, home string) {
		t.Helper()
		done := a.connect(t, "/bootstrap/connect", map[string]string{"address": home})
		if m := a.next(t); m.Type != TypeHome || m.Home != home {
			t.Fatalf("main heard %+v", m)
		}
		a.HomeReady(home)
		if got := answered(t, done); got.Next != "/" {
			t.Fatalf("Connect answered %+v", got)
		}
		a.opened(t, home)
	}
	a := newApp(t, t.TempDir(), offline())
	open(a, first)
	if w := a.get("/bootstrap/another"); w.Code != http.StatusNotFound {
		t.Fatalf("cyfr serves Connect to another itself: %d", w.Code)
	}
	a.quiet(t)
	in, main := io.Pipe()
	ran := make(chan error, 1)
	go func() { ran <- a.Run(in) }()
	t.Cleanup(func() {
		main.Close()
		<-ran
	})
	if _, err := io.WriteString(main, `{"version":1,"type":"leave"}`+"\n"); err != nil {
		t.Fatal(err)
	}
	if m := a.next(t); m.Type != TypeLocked || m.Home != "" {
		t.Fatalf("main heard %+v, not a lock keeping to none", m)
	}
	a.quiet(t)
	if got := a.post(t, "/bootstrap/state", map[string]string{}); got.Next != "" || got.Resume != "" || got.Home != first {
		t.Fatalf("the chooser shows %+v", got)
	}
	if w := a.get("/"); w.Code != http.StatusSeeOther {
		t.Fatal("the device's pages of the CYFR left are still served")
	}
	open(a, second)
	if c, err := a.Clients.Load(); err != nil || c.Home != second {
		t.Fatalf("launch would open %+v (%v), not the CYFR chosen last", c, err)
	}
	if got := a.post(t, "/bootstrap/state", map[string]string{}); got.Home != second {
		t.Fatalf("the chooser names %+v", got)
	}
}

// The device's pages are served only once main was told the CYFR opened:
// a write of opened that failed opens nothing, and the next Connect goes
// on as if this one never ran.
func TestAFailedWriteOfOpenedServesNoDevicePage(t *testing.T) {
	a := newApp(t, t.TempDir(), offline())
	send := a.Send
	a.Send = func(m Message) error {
		if m.Type == TypeOpened {
			return errors.New("main's pipe is gone")
		}
		return send(m)
	}
	done := a.connect(t, "/bootstrap/connect", map[string]string{"address": "cyfr.example.com"})
	a.next(t)
	a.HomeReady("https://cyfr.example.com")
	if got := answered(t, done); got.Next != "" || got.Error == "" {
		t.Fatalf("a Connect whose opened was not written answered %+v", got)
	}
	if w := a.get("/"); w.Code != http.StatusSeeOther {
		t.Fatal("the device's pages were served though main was never told")
	}
	a.Send = send
	again := a.connect(t, "/bootstrap/connect", map[string]string{"address": "cyfr.example.com"})
	a.next(t)
	a.HomeReady("https://cyfr.example.com")
	if got := answered(t, again); got.Next != "/" {
		t.Fatalf("the next Connect answered %+v", got)
	}
	a.opened(t, "https://cyfr.example.com")
}

// Every locked names the CYFR cyfr holds committed, as home named it, and
// none before one is committed: main keeps to what it names.
func TestLockedNamesTheCommittedCYFR(t *testing.T) {
	a := newApp(t, t.TempDir(), offline())
	a.Lock("Locked.")
	if m := a.next(t); m.Type != TypeLocked || m.Home != "" || m.Account != "" {
		t.Fatalf("before a commit main heard %+v", m)
	}
	done := a.connect(t, "/bootstrap/connect", map[string]string{"address": "cyfr.example.com"})
	a.next(t)
	a.HomeReady("https://cyfr.example.com")
	answered(t, done)
	a.opened(t, "https://cyfr.example.com")
	a.Lock("Locked.")
	if m := a.next(t); m.Type != TypeLocked || m.Home != "https://cyfr.example.com" || m.Account != account.DefaultDirectory {
		t.Fatalf("after the commit main heard %+v", m)
	}
}
