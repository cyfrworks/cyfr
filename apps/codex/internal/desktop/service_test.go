// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package desktop

import (
	"bufio"
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
	proposed   atomic.Uint64
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
		Tell: func(m Message) {
			if m.Type == TypeHome {
				a.proposed.Store(m.Attempt)
			}
			a.sent <- m
		},
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

// ready is main's home-ready for home, echoing the last attempt proposed.
func (a *app) ready(home string) { a.HomeReady(home, a.proposed.Load()) }

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
	a.ready("https://another.example.com")
	if w := a.get("/"); w.Code != http.StatusSeeOther {
		t.Fatal("the device's pages were served before main was ready")
	}
	a.ready("https://cyfr.example.com")
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
	a.ready("https://another.example.com")
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
	a.ready("https://cyfr.example.com")
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
	again.ready("https://cyfr.example.com")
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
	opened.ready("https://cyfr.example.com")
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
	a.ready("https://cyfr.example.com")
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
	a.ready("https://cyfr.example.com")
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
	a.ready("https://cyfr.example.com")
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
	a.ready("https://cyfr.example.com")
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
	first.ready("https://cyfr.example.com")
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
	a.ready("https://cyfr.example.com")
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
	a.ready("https://cyfr.example.com")
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
	a.ready("https://cyfr.example.com")
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
	a.ready("https://cyfr.example.com")
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
	a.ready("https://cyfr.example.com")
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
		a.ready(home)
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
	a.ready("https://cyfr.example.com")
	answered(t, done)
	a.opened(t, "https://cyfr.example.com")
	a.Lock("Locked.")
	if m := a.next(t); m.Type != TypeLocked || m.Home != "https://cyfr.example.com" || m.Account != account.DefaultDirectory {
		t.Fatalf("after the commit main heard %+v", m)
	}
}

const (
	localFolder  = "/home/ada/cyfr"
	localAddress = "http://localhost:4000"
)

// rememberLocal is a over a client record that selects a folder on this
// computer, whose CYFR's settings name directory and which answers while
// running holds.
func rememberLocal(t *testing.T, dir, directory string, running *atomic.Bool) *app {
	t.Helper()
	a := newApp(t, dir, offline())
	if err := a.Clients.SelectProject(localFolder); err != nil {
		t.Fatal(err)
	}
	a.Local = func(project string) (Local, error) {
		if project != localFolder {
			t.Errorf("the app read %s, not the folder remembered", project)
		}
		return Local{Shell: shell.Config{Address: localAddress, Client: offline(), Directory: directory},
			Answers: func(context.Context) error {
				if running.Load() {
					return nil
				}
				return errors.New("The CYFR in " + localFolder + " is not running.")
			}}, nil
	}
	return a
}

func (a *app) record(t *testing.T) string {
	t.Helper()
	c, err := a.Clients.Load()
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := json.Marshal(c)
	return string(raw)
}

// The folder remembered opens on one press: its address is in the
// chooser's field, and Connect opens it with the account service its own
// settings name, reading no sign-in page and asking nothing, cyfr.run or
// not.
func TestARememberedLocalCYFROpensOnOnePress(t *testing.T) {
	for _, tc := range []struct{ name, directory, origin string }{
		{"cyfr.run", account.DefaultDirectory, account.DefaultDirectory},
		{"another https service", "https://accounts.example.com/cyfr", "https://accounts.example.com"},
		{"its own", localAddress, localAddress},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var running atomic.Bool
			running.Store(true)
			a := rememberLocal(t, t.TempDir(), tc.directory, &running)
			before := a.record(t)
			shown := a.post(t, "/bootstrap/state", map[string]string{})
			if shown != (answer{Home: localAddress}) {
				t.Fatalf("the chooser shows %+v", shown)
			}
			done := a.connect(t, "/bootstrap/connect", map[string]string{"address": shown.Home})
			if m := a.next(t); m != (Message{Type: TypeHome, Home: localAddress, Account: tc.origin, Attempt: 1}) {
				t.Fatalf("main heard %+v", m)
			}
			if w := a.get("/"); w.Code != http.StatusSeeOther {
				t.Fatal("the device's pages were served before main was ready")
			}
			a.ready(localAddress)
			want := answer{Home: localAddress, Next: "/"}
			if got := answered(t, done); got != want {
				t.Fatalf("answered %+v", got)
			}
			a.opened(t, localAddress)
			if w := a.get("/"); w.Code != http.StatusOK || !strings.Contains(w.Body.String(), "Set up CYFR") {
				t.Fatalf("the device's pages are not served: %d %s", w.Code, w.Body)
			}
			if n := a.discovered.Load(); n != 0 {
				t.Fatalf("%d sign-in pages were read", n)
			}
			if got := a.record(t); got != before {
				t.Fatalf("the record became %s", got)
			}
			if got := a.post(t, "/bootstrap/state", map[string]string{}); got != want {
				t.Fatalf("the chooser of the open CYFR shows %+v", got)
			}
			a.Lock("Locked.")
			if m := a.next(t); m != (Message{Type: TypeLocked, Home: localAddress, Account: tc.origin, Attempt: 1}) {
				t.Fatalf("main heard %+v", m)
			}
		})
	}
}

// A CYFR with tailnet access opens over the route read for it, which every
// locked names again.
func TestALocalCYFROnItsTailnetNamesItsRoute(t *testing.T) {
	const home = "https://box.tail9f3a3c.ts.net"
	a := newApp(t, t.TempDir(), offline())
	if err := a.Clients.SelectProject(localFolder); err != nil {
		t.Fatal(err)
	}
	a.Local = func(string) (Local, error) {
		return Local{Shell: shell.Config{Address: home, Client: offline(), Directory: account.DefaultDirectory},
			Proxy: "socks5://127.0.0.1:1055", Resolver: "MAP * ~NOTFOUND, EXCLUDE 127.0.0.1",
			Answers: func(context.Context) error { return nil }}, nil
	}
	done := a.connect(t, "/bootstrap/connect", map[string]string{"address": home})
	want := Message{Type: TypeHome, Home: home, Account: account.DefaultDirectory, Attempt: 1,
		Proxy: "socks5://127.0.0.1:1055", Resolver: "MAP * ~NOTFOUND, EXCLUDE 127.0.0.1"}
	if m := a.next(t); m != want {
		t.Fatalf("main heard %+v", m)
	}
	a.ready(home)
	answered(t, done)
	a.opened(t, home)
	a.Lock("Locked.")
	want.Type = TypeLocked
	if m := a.next(t); m != want {
		t.Fatalf("main heard %+v", m)
	}
}

// A CYFR on this computer that does not answer is named and opens nothing;
// the same press opens it once it answers.
func TestALocalCYFRThatDoesNotAnswerIsNamedAndOpensNothing(t *testing.T) {
	var running atomic.Bool
	a := rememberLocal(t, t.TempDir(), account.DefaultDirectory, &running)
	before := a.record(t)
	got := a.post(t, "/bootstrap/connect", map[string]string{"address": localAddress})
	want := "The CYFR in /home/ada/cyfr is not running."
	if got != (answer{Error: want}) {
		t.Fatalf("answered %+v", got)
	}
	a.quiet(t)
	if w := a.get("/"); w.Code != http.StatusSeeOther || a.record(t) != before {
		t.Fatal("a CYFR that does not answer opened or changed the record")
	}
	running.Store(true)
	done := a.connect(t, "/bootstrap/connect", map[string]string{"address": localAddress})
	if m := a.next(t); m.Type != TypeHome {
		t.Fatalf("main heard %+v", m)
	}
	a.ready(localAddress)
	if got := answered(t, done); got.Next != "/" {
		t.Fatalf("answered %+v", got)
	}
}

// The edges of plain http: a local CYFR naming any origin but its own,
// this computer's others included, opens nothing and is sent nothing.
func TestALocalCYFRTakesPlainHTTPOnlyAtItsOwnOrigin(t *testing.T) {
	for _, directory := range []string{"http://localhost:4100", "http://127.0.0.1:4000", "http://127.0.0.1:7340",
		"http://accounts.example.com", "not an address"} {
		var asked atomic.Bool
		var running atomic.Bool
		running.Store(true)
		a := rememberLocal(t, t.TempDir(), directory, &running)
		read := a.Local
		a.Local = func(project string) (Local, error) {
			l, err := read(project)
			l.Answers = func(context.Context) error { asked.Store(true); return nil }
			return l, err
		}
		if got := a.post(t, "/bootstrap/connect", map[string]string{"address": localAddress}); got.Next != "" || !strings.Contains(got.Error, directory) {
			t.Errorf("%s: answered %+v", directory, got)
		}
		a.quiet(t)
		if asked.Load() {
			t.Errorf("%s: the CYFR was asked anything", directory)
		}
	}
}

// The other edge: a CYFR elsewhere that names this computer, or any plain
// http address, as its account service is refused by the reader, and
// nothing of the app goes there.
func TestACYFRElsewhereNamingPlainHTTPIsRefused(t *testing.T) {
	for _, directory := range []string{localAddress, "http://accounts.example.com"} {
		var reached []string
		client := &http.Client{Transport: roundTrip(func(r *http.Request) (*http.Response, error) {
			reached = append(reached, r.URL.String())
			page := `<div data-account-directory="` + directory + `"></div>`
			return &http.Response{StatusCode: http.StatusOK, Header: http.Header{}, Body: io.NopCloser(strings.NewReader(page)), Request: r}, nil
		})}
		a := newApp(t, t.TempDir(), client)
		a.Discover = account.Discover
		if got := a.post(t, "/bootstrap/connect", map[string]string{"address": "cyfr.example.com"}); got.Next != "" || got.Confirm != "" || got.Error == "" {
			t.Errorf("%s: answered %+v", directory, got)
		}
		a.quiet(t)
		if len(reached) != 1 || reached[0] != "https://cyfr.example.com/login" {
			t.Errorf("%s: the app reached %v", directory, reached)
		}
	}
}

// Plain http opens the remembered folder's CYFR and nothing else: with no
// folder remembered, or at another address, Connect takes https alone.
func TestOnlyTheRememberedFolderOpensOverPlainHTTP(t *testing.T) {
	a := newApp(t, t.TempDir(), offline())
	a.Local = func(string) (Local, error) {
		t.Error("a folder was read with none remembered")
		return Local{}, errors.New("none")
	}
	if got := a.post(t, "/bootstrap/connect", map[string]string{"address": localAddress}); got.Error == "" {
		t.Fatalf("no folder remembered: answered %+v", got)
	}
	var running atomic.Bool
	running.Store(true)
	b := rememberLocal(t, t.TempDir(), account.DefaultDirectory, &running)
	if got := b.post(t, "/bootstrap/connect", map[string]string{"address": "http://localhost:4100"}); got.Error == "" {
		t.Fatalf("another local address: answered %+v", got)
	}
	a.quiet(t)
	b.quiet(t)
}

// A folder that cannot be read says so on the chooser, and Connect to a
// CYFR elsewhere still goes on.
func TestAFolderThatCannotBeReadLeavesConnect(t *testing.T) {
	a := newApp(t, t.TempDir(), offline())
	if err := a.Clients.SelectProject(localFolder); err != nil {
		t.Fatal(err)
	}
	a.Local = func(string) (Local, error) { return Local{}, errors.New("no .env") }
	if got := a.post(t, "/bootstrap/state", map[string]string{}); got.Error != "The app cannot read the CYFR in /home/ada/cyfr (no .env)." {
		t.Fatalf("the chooser shows %+v", got)
	}
	done := a.connect(t, "/bootstrap/connect", map[string]string{"address": "cyfr.example.com"})
	if m := a.next(t); m.Type != TypeHome || m.Home != "https://cyfr.example.com" {
		t.Fatalf("main heard %+v", m)
	}
	a.ready("https://cyfr.example.com")
	answered(t, done)
}

// The chooser shown again offers the CYFR open, which the record names
// only once it admitted this device: never the one the record still holds.
func TestTheChooserOffersTheCYFROpenNotTheRecords(t *testing.T) {
	for _, held := range []shell.ClientRecord{{Project: localFolder}, {Home: "https://first.example.com", Directory: account.DefaultDirectory}} {
		a := newApp(t, t.TempDir(), offline())
		held.ClientID, held.Certificate = "pcl_held", json.RawMessage(`{"held":1}`)
		if err := a.Clients.Save(held); err != nil {
			t.Fatal(err)
		}
		done := a.connect(t, "/bootstrap/connect", map[string]string{"address": "second.example.com"})
		a.next(t)
		a.ready("https://second.example.com")
		answered(t, done)
		a.opened(t, "https://second.example.com")
		want := answer{Home: "https://second.example.com", Next: "/"}
		if got := a.post(t, "/bootstrap/state", map[string]string{}); got != want {
			t.Errorf("over %+v the chooser shows %+v", held, got)
		}
	}
}

// Connect takes the folder's address in every spelling of it and opens it
// in its one.
func TestConnectTakesEverySpellingOfTheFoldersAddress(t *testing.T) {
	for _, tc := range []struct{ home, typed string }{
		{"http://localhost", "http://localhost"},
		{"http://localhost", "http://localhost:80"},
		{"http://localhost", " HTTP://LocalHost:80/ "},
		{"https://cyfr.example.com", "cyfr.example.com:443"},
		{localAddress, "http://localhost:4000/"},
	} {
		a := newApp(t, t.TempDir(), offline())
		if err := a.Clients.SelectProject(localFolder); err != nil {
			t.Fatal(err)
		}
		a.Local = func(string) (Local, error) {
			return Local{Shell: shell.Config{Address: tc.home, Client: offline(), Directory: account.DefaultDirectory},
				Answers: func(context.Context) error { return nil }}, nil
		}
		done := a.connect(t, "/bootstrap/connect", map[string]string{"address": tc.typed})
		if m := a.next(t); m.Type != TypeHome || m.Home != tc.home {
			t.Fatalf("%q: main heard %+v", tc.typed, m)
		}
		a.ready(tc.home)
		if got := answered(t, done); got.Next != "/" {
			t.Fatalf("%q answered %+v", tc.typed, got)
		}
		if n := a.discovered.Load(); n != 0 {
			t.Fatalf("%q was discovered", tc.typed)
		}
	}
}

// The folder is read as Connect is pressed: an address shown from an
// earlier reading opens nothing, and the chooser says the one it has now.
func TestAnAddressFromAnEarlierReadingOpensNothing(t *testing.T) {
	a := newApp(t, t.TempDir(), offline())
	if err := a.Clients.SelectProject(localFolder); err != nil {
		t.Fatal(err)
	}
	now := localAddress
	a.Local = func(string) (Local, error) {
		return Local{Shell: shell.Config{Address: now, Client: offline(), Directory: account.DefaultDirectory},
			Answers: func(context.Context) error { return nil }}, nil
	}
	shown := a.post(t, "/bootstrap/state", map[string]string{}).Home
	now = "http://localhost:4200"
	got := a.post(t, "/bootstrap/connect", map[string]string{"address": shown})
	if got.Next != "" || got.Error != "The CYFR in /home/ada/cyfr is at http://localhost:4200. Connect to that address." {
		t.Fatalf("answered %+v", got)
	}
	a.quiet(t)
}

// openedFolder is a with the folder's CYFR open, as a press of Connect
// leaves it.
func (a *app) openedFolder(t *testing.T) {
	t.Helper()
	done := a.connect(t, "/bootstrap/connect", map[string]string{"address": localAddress})
	a.next(t)
	a.ready(localAddress)
	if got := answered(t, done); got.Next != "/" {
		t.Fatalf("Connect answered %+v", got)
	}
	a.opened(t, localAddress)
}

// After a lock the passkey's way on to a folder's CYFR, a page loaded with
// the sign-in kept and no connection of the shell's, asks that CYFR at the
// press and goes on only on its answer. The chooser shown asks it nothing.
func TestThePasskeyWayOnNeedsTheFoldersCYFRStillAnswering(t *testing.T) {
	var running atomic.Bool
	running.Store(true)
	a := rememberLocal(t, t.TempDir(), account.DefaultDirectory, &running)
	var asked atomic.Int32
	read := a.Local
	a.Local = func(project string) (Local, error) {
		l, err := read(project)
		answers := l.Answers
		l.Answers = func(ctx context.Context) error {
			asked.Add(1)
			return answers(ctx)
		}
		return l, err
	}
	a.openedFolder(t)
	a.Lock("Locked.")
	a.next(t)
	open := answer{Home: localAddress, Next: "/"}
	running.Store(false)
	asked.Store(0)
	if got := a.post(t, "/bootstrap/state", map[string]string{}); got != open || asked.Load() != 0 {
		t.Fatalf("the chooser shows %+v, having asked %d times", got, asked.Load())
	}
	gone := answer{Home: localAddress, Error: "The CYFR in " + localFolder + " is not running."}
	if got := a.post(t, "/bootstrap/connect", map[string]string{"address": localAddress}); got != gone {
		t.Fatalf("with the folder's CYFR gone the press answered %+v", got)
	}
	a.quiet(t)
	running.Store(true)
	if got := a.post(t, "/bootstrap/connect", map[string]string{"address": localAddress}); got != open {
		t.Fatalf("with it back the press answered %+v", got)
	}
	a.quiet(t)
	if asked.Load() != 2 || a.discovered.Load() != 0 {
		t.Fatalf("two presses asked %d times and read %d sign-in pages", asked.Load(), a.discovered.Load())
	}
}

// Try again's press comes with no lock before it: a page of the open
// folder's CYFR did not load. It asks that CYFR all the same.
func TestTryAgainNeedsTheFoldersCYFRStillAnswering(t *testing.T) {
	var running atomic.Bool
	running.Store(true)
	a := rememberLocal(t, t.TempDir(), account.DefaultDirectory, &running)
	a.openedFolder(t)
	running.Store(false)
	gone := answer{Home: localAddress, Error: "The CYFR in " + localFolder + " is not running."}
	if got := a.post(t, "/bootstrap/connect", map[string]string{"address": localAddress}); got != gone {
		t.Fatalf("with the open folder's CYFR gone the press answered %+v", got)
	}
	a.quiet(t)
	running.Store(true)
	if got := a.post(t, "/bootstrap/connect", map[string]string{"address": localAddress}); got != (answer{Home: localAddress, Next: "/"}) {
		t.Fatalf("with it back the press answered %+v", got)
	}
	a.quiet(t)
}

// A lock ends the press while it asks, and a second press waits for none.
func TestALockEndsThePasskeyWayOnWhileItAsks(t *testing.T) {
	var running atomic.Bool
	running.Store(true)
	a := rememberLocal(t, t.TempDir(), account.DefaultDirectory, &running)
	var held atomic.Bool
	var once sync.Once
	asking := make(chan struct{})
	read := a.Local
	a.Local = func(project string) (Local, error) {
		l, err := read(project)
		answers := l.Answers
		l.Answers = func(ctx context.Context) error {
			if !held.Load() {
				return answers(ctx)
			}
			once.Do(func() { close(asking) })
			<-ctx.Done()
			return nil // an answer that came as the lock did
		}
		return l, err
	}
	a.openedFolder(t)
	held.Store(true)
	press := a.connect(t, "/bootstrap/connect", map[string]string{"address": localAddress})
	select {
	case <-asking:
	case got := <-press:
		t.Fatalf("the press answered %+v and asked nothing", got)
	case <-time.After(5 * time.Second):
		t.Fatal("the press asked nothing")
	}
	second := a.connect(t, "/bootstrap/connect", map[string]string{"address": localAddress})
	if got := answered(t, second); got != (answer{Error: busySentence}) {
		t.Fatalf("a second press answered %+v", got)
	}
	a.Lock("Locked.")
	if got := answered(t, press); got != (answer{Error: lockedSentence}) {
		t.Fatalf("a press the lock ended answered %+v", got)
	}
}

// Main's leave lets go of the folder's CYFR whole: the passkey's way on to
// the CYFR chosen next asks that folder nothing.
func TestAFolderLeftIsAskedNoMore(t *testing.T) {
	const next = "https://bob.example.com"
	var running atomic.Bool
	running.Store(true)
	a := rememberLocal(t, t.TempDir(), account.DefaultDirectory, &running)
	a.openedFolder(t)
	a.lock("", true) // main's leave, as Run takes it
	if m := a.next(t); m.Type != TypeLocked || m.Home != "" {
		t.Fatalf("main heard %+v, not a lock naming none", m)
	}
	done := a.connect(t, "/bootstrap/connect", map[string]string{"address": next})
	a.next(t)
	a.ready(next)
	answered(t, done)
	a.opened(t, next)
	running.Store(false)
	if got := a.post(t, "/bootstrap/connect", map[string]string{"address": next}); got != (answer{Home: next, Next: "/"}) {
		t.Fatalf("the press at the CYFR chosen next answered %+v", got)
	}
}

// With a CYFR open, Connect takes that CYFR's own address alone, a CYFR
// elsewhere's too, whose press reads and proposes nothing.
func TestConnectOfAnOpenCYFRTakesItsOwnAddressAlone(t *testing.T) {
	const home = "https://cyfr.example.com"
	a := newApp(t, t.TempDir(), offline())
	done := a.connect(t, "/bootstrap/connect", map[string]string{"address": home})
	a.next(t)
	a.ready(home)
	answered(t, done)
	a.opened(t, home)
	a.discovered.Store(0)
	if got := a.post(t, "/bootstrap/connect", map[string]string{"address": home}); got != (answer{Home: home, Next: "/"}) {
		t.Fatalf("its own address answered %+v", got)
	}
	for _, other := range []string{"https://bob.example.com", "https://cyfr.example.com:8443", localAddress, "not an address", ""} {
		if got := a.post(t, "/bootstrap/connect", map[string]string{"address": other}); got.Next != "" || !strings.Contains(got.Error, "connected to a CYFR already") {
			t.Errorf("%q answered %+v", other, got)
		}
	}
	if n := a.discovered.Load(); n != 0 {
		t.Fatalf("%d sign-in pages were read", n)
	}
	a.quiet(t)
}

// A folder remembered never resumes at launch: the chooser has its address
// and nothing to connect by itself, also once another CYFR was chosen over
// it, which the record keeps the folder under.
func TestAFolderNeverResumes(t *testing.T) {
	var running atomic.Bool
	running.Store(true)
	dir := t.TempDir()
	want := answer{Home: localAddress}
	first := rememberLocal(t, dir, account.DefaultDirectory, &running)
	if got := first.post(t, "/bootstrap/state", map[string]string{}); got != want {
		t.Fatalf("a launch shows %+v", got)
	}
	const elsewhere = "https://second.example.com"
	done := first.connect(t, "/bootstrap/connect", map[string]string{"address": elsewhere})
	first.next(t)
	first.ready(elsewhere)
	answered(t, done)
	first.opened(t, elsewhere)
	first.End()
	again := newApp(t, dir, offline())
	again.Local = first.Local
	if got := again.post(t, "/bootstrap/state", map[string]string{}); got != want {
		t.Fatalf("the launch after another CYFR was chosen shows %+v", got)
	}
	again.quiet(t)
}

// cancellable is a Connect to address whose chooser gives up when the test
// says, as its sixty seconds passing do, and its answer once it has.
func (a *app) cancellable(t *testing.T, address string) (giveUp func() answer) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan *httptest.ResponseRecorder, 1)
	go func() {
		done <- a.request(ctx, "/bootstrap/connect", map[string]string{"address": address}, nil)
	}()
	return func() answer {
		t.Helper()
		cancel()
		var got answer
		_ = json.Unmarshal((<-done).Body.Bytes(), &got)
		return got
	}
}

// Ownership has one attempt at a time: a Connect that timed out, followed
// by another and by the first's CYFR again, is numbered anew each time, and
// main's answer to an earlier number neither opens nor ends the one waiting,
// though it names the same CYFR.
func TestAnAnswerToAnEarlierAttemptChangesNothing(t *testing.T) {
	const first, second = "https://cyfr.example.com:8443", "https://cyfr.example.com:9443"
	a := newApp(t, t.TempDir(), offline())
	var attempts []uint64
	for _, home := range []string{first, second} {
		giveUp := a.cancellable(t, home)
		m := a.next(t)
		if m.Type != TypeHome || m.Home != home {
			t.Fatalf("main heard %+v", m)
		}
		attempts = append(attempts, m.Attempt)
		if got := giveUp(); got.Next != "" || got.Error == "" {
			t.Fatalf("a Connect given up answered %+v", got)
		}
	}
	done := a.connect(t, "/bootstrap/connect", map[string]string{"address": first})
	current := a.next(t).Attempt
	if attempts[0] != 1 || attempts[1] != 2 || current != 3 {
		t.Fatalf("the attempts were numbered %v and %d", attempts, current)
	}
	for _, stale := range []uint64{attempts[0], attempts[1], current + 1} {
		a.HomeFailed(first, stale)
		a.HomeReady(first, stale)
		a.HomeFailed(second, stale)
		a.HomeReady(second, stale)
	}
	a.HomeReady(second, current)
	select {
	case got := <-done:
		t.Fatalf("an answer to another attempt ended the one waiting: %+v", got)
	case <-time.After(100 * time.Millisecond): // sleep-ok: how long the test watches for what must not happen
	}
	a.quiet(t)
	if w := a.get("/"); w.Code != http.StatusSeeOther {
		t.Fatal("an answer to another attempt served the device's pages")
	}
	a.HomeReady(first, current)
	if got := answered(t, done); got.Next != "/" || got.Home != first {
		t.Fatalf("the current attempt answered %+v", got)
	}
	a.opened(t, first)
}

// A failure for a Connect that timed out, arriving while the next reads
// its CYFR, locks nothing and ends nothing: that Connect proposes and opens.
func TestALateFailureDuringTheNextDiscoveryChangesNothing(t *testing.T) {
	const first, second = "https://cyfr.example.com", "https://bob.example.com"
	a := newApp(t, t.TempDir(), offline())
	giveUp := a.cancellable(t, first)
	timedOut := a.next(t)
	giveUp()
	reading, release := make(chan struct{}), make(chan struct{})
	discover := a.Discover
	a.Discover = func(ctx context.Context, c *http.Client, home string) (account.Discovered, error) {
		close(reading)
		<-release
		if err := ctx.Err(); err != nil {
			return account.Discovered{}, err
		}
		return discover(ctx, c, home)
	}
	done := a.connect(t, "/bootstrap/connect", map[string]string{"address": second})
	<-reading
	a.HomeFailed(first, timedOut.Attempt)
	a.HomeReady(first, timedOut.Attempt)
	a.quiet(t)
	close(release)
	if m := a.next(t); m.Type != TypeHome || m.Home != second {
		t.Fatalf("the Connect in discovery proposed nothing: %+v", m)
	}
	a.ready(second)
	if got := answered(t, done); got.Next != "/" {
		t.Fatalf("the Connect in discovery answered %+v", got)
	}
}

// Main's home-failed for the attempt waiting ends it unopened and is no
// lock: the chooser's answer names its sentence, main hears nothing, the
// record stays and the next Connect goes on.
func TestHomeFailedEndsItsAttemptAloneAndIsNoLock(t *testing.T) {
	const home = "https://cyfr.example.com"
	a := newApp(t, t.TempDir(), offline())
	in, main := io.Pipe()
	ran := make(chan error, 1)
	go func() { ran <- a.Run(in) }()
	t.Cleanup(func() {
		main.Close()
		<-ran
	})
	done := a.connect(t, "/bootstrap/connect", map[string]string{"address": home})
	if m := a.next(t); m.Type != TypeHome || m.Attempt != 1 {
		t.Fatalf("main heard %+v", m)
	}
	if _, err := io.WriteString(main, `{"version":1,"type":"home-failed","home":"`+home+`","attempt":1}`+"\n"); err != nil {
		t.Fatal(err)
	}
	if got, want := answered(t, done), (answer{Home: home, Notice: "uncleared"}); got != want {
		t.Fatalf("answered %+v", got)
	}
	a.quiet(t)
	if c, err := a.Clients.Load(); err != nil || c.Home != "" {
		t.Fatalf("remembered %+v, %v", c, err)
	}
	if w := a.get("/"); w.Code != http.StatusSeeOther {
		t.Fatal("a failed attempt served the device's pages")
	}
	again := a.connect(t, "/bootstrap/connect", map[string]string{"address": home})
	if m := a.next(t); m.Type != TypeHome || m.Attempt != 2 {
		t.Fatalf("the next Connect proposed %+v", m)
	}
	if _, err := io.WriteString(main, `{"version":1,"type":"home-ready","home":"`+home+`","attempt":2}`+"\n"); err != nil {
		t.Fatal(err)
	}
	if got := answered(t, again); got.Next != "/" {
		t.Fatalf("the next Connect answered %+v", got)
	}
}

// Nothing is written to main while holding what a lock needs: with main's
// pipe never read, and every message given to it through the writer's
// queue, as desktop-serve gives them (cmd's runDesktopServe), a lock
// returns within its bound while a Connect's proposal waits for main, and
// once main was told the CYFR opened.
func TestALockWaitsOnNoProposalOrOpenedMainHasNotRead(t *testing.T) {
	for _, at := range []string{"the proposal", "opened"} {
		t.Run(at, func(t *testing.T) {
			a := newApp(t, t.TempDir(), offline())
			read, write := io.Pipe()
			t.Cleanup(func() { read.Close() })
			to := NewWriter(write, nil)
			heard := a.Tell
			a.Tell = func(m Message) {
				heard(m)
				_ = to.Queue(m)
			}
			done := a.connect(t, "/bootstrap/connect", map[string]string{"address": "cyfr.example.com"})
			if m := a.next(t); m.Type != TypeHome {
				t.Fatalf("main was proposed %+v", m)
			}
			if at == "opened" {
				// Main's answer waits on nothing of the test's: a write held
				// under the service's mutex shows as no answer to the Connect.
				go a.ready("https://cyfr.example.com")
				if got := answered(t, done); got.Next != "/" {
					t.Fatalf("Connect answered %+v", got)
				}
				a.opened(t, "https://cyfr.example.com")
			}
			locked := make(chan struct{})
			go func() {
				defer close(locked)
				a.Lock("Locked.")
			}()
			select {
			case <-locked:
			case <-time.After(2 * time.Second):
				t.Fatal("the lock waited on main")
			}
		})
	}
}

// Everything begun for a folder's CYFR ends as the app lets go of it: a
// reading the app made and did not select at once, the CYFR selected as
// the app leaves it (main's leave) or ends, and none before.
func TestTheAppEndsWhatAFolderBeganAsItLetsGo(t *testing.T) {
	for name, letGo := range map[string]func(a *app){
		"left":  func(a *app) { a.lock("", true) },
		"ended": func(a *app) { a.End() },
	} {
		t.Run(name, func(t *testing.T) {
			var running atomic.Bool
			running.Store(true)
			a := rememberLocal(t, t.TempDir(), account.DefaultDirectory, &running)
			var works []*shell.Work
			var mu sync.Mutex
			read := a.Local
			a.Local = func(project string) (Local, error) {
				l, err := read(project)
				l.Work = shell.NewWork(t.Context())
				mu.Lock()
				works = append(works, l.Work)
				mu.Unlock()
				return l, err
			}
			// The lock's hide, the first act after locked, finds the CYFR's
			// Work not yet ended: the lock's one entry runs before the let-go.
			var endedAtHide atomic.Int32
			adapt := a.Shell
			a.Shell = func(c *shell.Config) {
				adapt(c)
				hide := c.Restart
				c.Restart = func() {
					mu.Lock()
					if works[len(works)-1].Context().Err() != nil {
						endedAtHide.Add(1)
					}
					mu.Unlock()
					hide()
				}
			}
			a.post(t, "/bootstrap/state", map[string]string{})
			a.openedFolder(t)
			mu.Lock()
			unselected, selected := works[:len(works)-1], works[len(works)-1]
			mu.Unlock()
			if len(unselected) == 0 {
				t.Fatal("the app read the folder only to select it")
			}
			for _, w := range unselected {
				if w.Context().Err() == nil {
					t.Fatal("a reading the app did not select was not ended")
				}
			}
			a.lock("Locked.", false)
			if selected.Context().Err() != nil {
				t.Fatal("the CYFR selected was ended while the app held it")
			}
			letGo(a)
			if selected.Context().Err() == nil {
				t.Fatal("the CYFR the app let go of was not ended")
			}
			if n := endedAtHide.Load(); n != 0 {
				t.Fatalf("%d hides found the CYFR's Work ended already: the let-go ran before the lock", n)
			}
		})
	}
}

// A write to main that fails ends the service, the app being gone: with
// main's pipe closed after it read the proposal, before opened is written,
// the service ends once that write fails, and serves nothing afterwards,
// neither the device's pages nor the chooser.
func TestAWriteToMainThatFailsEndsTheService(t *testing.T) {
	a := newApp(t, t.TempDir(), offline())
	read, write := io.Pipe()
	to := NewWriter(write, a.End)
	heard := a.Tell
	a.Tell = func(m Message) {
		heard(m)
		_ = to.Queue(m)
	}
	done := a.connect(t, "/bootstrap/connect", map[string]string{"address": "cyfr.example.com"})
	if m := a.next(t); m.Type != TypeHome {
		t.Fatalf("main was proposed %+v", m)
	}
	if _, err := bufio.NewReader(read).ReadString('\n'); err != nil {
		t.Fatal(err)
	}
	read.Close()
	a.ready("https://cyfr.example.com")
	answered(t, done)
	a.opened(t, "https://cyfr.example.com")
	deadline := time.Now().Add(5 * time.Second)
	for a.get("/").Code != http.StatusServiceUnavailable && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond) // sleep-ok: polls the writer's own goroutine, bounded
	}
	if w := a.get("/"); w.Code != http.StatusServiceUnavailable {
		t.Fatalf("after the write of opened failed the device's pages answered %d", w.Code)
	}
	if w := a.get("/bootstrap/"); w.Code != http.StatusServiceUnavailable {
		t.Fatalf("after the write of opened failed the chooser answered %d", w.Code)
	}
}

// A lock tells main locked without waiting for main to take it: with main
// reading nothing, the lock returns all the same.
func TestALockTellsMainWithoutWaiting(t *testing.T) {
	a := newApp(t, t.TempDir(), offline())
	told := make(chan Message, 1)
	a.Tell = func(m Message) { told <- m }
	locked := make(chan struct{})
	go func() {
		defer close(locked)
		a.Lock("Locked.")
	}()
	select {
	case <-locked:
	case <-time.After(2 * time.Second):
		t.Fatal("the lock waited for main")
	}
	if m := <-told; m.Type != TypeLocked {
		t.Fatalf("main was told %+v", m)
	}
}

// folderWork is the app with the folder remembered, every reading of it
// under the one Work returned.
func folderWork(t *testing.T) (*app, *shell.Work) {
	t.Helper()
	var running atomic.Bool
	running.Store(true)
	a := rememberLocal(t, t.TempDir(), account.DefaultDirectory, &running)
	work := shell.NewWork(t.Context())
	read := a.Local
	a.Local = func(project string) (Local, error) {
		l, err := read(project)
		l.Work = work
		return l, err
	}
	return a, work
}

// A folder's Work has its holder with no gap: the service holds it by the
// time main is told opened, under the same hold of its mutex that
// publishes the pages, so the End a failed write of opened makes ends it,
// and nothing attaches it after that End.
func TestAFailedOpenedWriteEndsTheFolderWork(t *testing.T) {
	a, work := folderWork(t)
	r, w := io.Pipe()
	t.Cleanup(func() { r.Close(); w.Close() })
	ended := make(chan struct{})
	to := NewWriter(w, func() {
		a.End()
		close(ended)
	})
	var heldAtOpened atomic.Bool
	tell := a.Tell
	a.Tell = func(m Message) {
		tell(m)
		if m.Type == TypeOpened {
			// Told under the service's mutex, which guards here.
			heldAtOpened.Store(a.here != nil && a.here.Work == work)
		}
		if err := to.Queue(m); err != nil {
			t.Error(err)
		}
	}
	done := a.connect(t, "/bootstrap/connect", map[string]string{"address": localAddress})
	if _, err := bufio.NewReader(r).ReadString('\n'); err != nil {
		t.Fatal(err)
	}
	a.next(t)
	r.Close()
	a.ready(localAddress)
	answered(t, done)
	select {
	case <-ended:
	case <-time.After(5 * time.Second):
		t.Fatal("the failed write of opened did not end the service")
	}
	if !heldAtOpened.Load() {
		t.Fatal("main was told opened before the service held the folder's Work")
	}
	if work.Context().Err() == nil {
		t.Fatal("the failed write's End left the folder's Work alive")
	}
}

// A lock that lets go of the folder ends its Work on every way out: a hide
// that panics still ends it.
func TestLeavingEndsTheFolderWorkThoughTheHidePanics(t *testing.T) {
	a, work := folderWork(t)
	adapt := a.Shell
	a.Shell = func(c *shell.Config) {
		adapt(c)
		c.Restart = func() { panic("hide interrupted") }
	}
	a.openedFolder(t)
	func() {
		defer func() {
			if recover() != "hide interrupted" {
				t.Error("the hide did not panic")
			}
		}()
		a.lock("", true)
	}()
	if work.Context().Err() == nil {
		t.Fatal("the folder's Work outlived the panicking lock that let go of it")
	}
}
