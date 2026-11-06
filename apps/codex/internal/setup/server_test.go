// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package setup

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
)

// fakeSession is a Session whose state and answers the test sets, keeping
// what each request asked.
type fakeSession struct {
	mu    sync.Mutex
	state State
	err   error
	calls []string
}

func (f *fakeSession) record(call string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls = append(f.calls, call)
	return f.err
}

func (f *fakeSession) State() State {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.state
}
func (f *fakeSession) Start() error          { return f.record("start") }
func (f *fakeSession) Choose(o string) error { return f.record("choose " + o) }
func (f *fakeSession) called() []string      { f.mu.Lock(); defer f.mu.Unlock(); return f.calls }
func (f *fakeSession) set(st State, err error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.state, f.err = st, err
}

const (
	testPort  = 4321
	testToken = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	testHost  = "127.0.0.1:4321"
	pagesSelf = "http://127.0.0.1:4321"
)

// request is one request to srv: the pages' own, with their Host, token,
// origin and JSON type, apart from what edit changes.
func request(t *testing.T, srv *Server, method, path, body string, edit func(*http.Request)) *httptest.ResponseRecorder {
	t.Helper()
	var r *http.Request
	if body == "" {
		r = httptest.NewRequest(method, path, nil)
	} else {
		r = httptest.NewRequest(method, path, strings.NewReader(body))
		r.Header.Set("Content-Type", "application/json")
	}
	r.Host = testHost
	r.Header.Set(tokenHeader, testToken)
	if method == http.MethodPost {
		r.Header.Set("Origin", pagesSelf)
	}
	if edit != nil {
		edit(r)
	}
	w := httptest.NewRecorder()
	srv.ServeHTTP(w, r)
	return w
}

// Every request names this listener as its Host, by its address or as
// localhost, so a name a DNS rebinding points at loopback is served
// nothing: no page, no state.
func TestServerServesThisListenerAlone(t *testing.T) {
	f := &fakeSession{state: State{Phase: PhaseReady}}
	srv := NewServer(f, testToken, testPort)
	for _, host := range []string{"evil.example:4321", "127.0.0.1:4322", "127.0.0.1", "[::1]:4321", ""} {
		for _, path := range []string{"/", "/setup.js", "/api/state"} {
			w := request(t, srv, http.MethodGet, path, "", func(r *http.Request) { r.Host = host })
			if w.Code != http.StatusMisdirectedRequest {
				t.Errorf("GET %s with Host %q answered %d, want 421", path, host, w.Code)
			}
		}
	}
	for _, host := range []string{"127.0.0.1:4321", "localhost:4321"} {
		if w := request(t, srv, http.MethodGet, "/api/state", "", func(r *http.Request) { r.Host = host }); w.Code != http.StatusOK {
			t.Errorf("GET /api/state with Host %q answered %d, want 200", host, w.Code)
		}
	}
}

// The state and every action need the run's token; the pages' files do
// not, and carry no secret.
func TestServerRequiresTheRunsToken(t *testing.T) {
	f := &fakeSession{state: State{Phase: PhaseReady}}
	srv := NewServer(f, testToken, testPort)
	for _, token := range []string{"", "wrong", testToken[:63], testToken + "0"} {
		set := func(r *http.Request) { r.Header.Set(tokenHeader, token) }
		if w := request(t, srv, http.MethodGet, "/api/state", "", set); w.Code != http.StatusForbidden {
			t.Errorf("the state with token %q answered %d, want 403", token, w.Code)
		}
		if w := request(t, srv, http.MethodPost, "/api/start", `{}`, set); w.Code != http.StatusForbidden {
			t.Errorf("a start with token %q answered %d, want 403", token, w.Code)
		}
	}
	if calls := f.called(); len(calls) != 0 {
		t.Errorf("requests without the token reached the session: %v", calls)
	}
	for path, kind := range map[string]string{"/": "text/html; charset=utf-8", "/setup.js": "text/javascript; charset=utf-8", "/setup.css": "text/css; charset=utf-8", "/logo.png": "image/png"} {
		w := request(t, srv, http.MethodGet, path, "", func(r *http.Request) { r.Header.Del(tokenHeader) })
		if w.Code != http.StatusOK || w.Header().Get("Content-Type") != kind {
			t.Errorf("GET %s answered %d %q, want 200 %q", path, w.Code, w.Header().Get("Content-Type"), kind)
		}
		if csp := w.Header().Get("Content-Security-Policy"); !strings.Contains(csp, "default-src 'none'") || !strings.Contains(csp, "frame-ancestors 'none'") {
			t.Errorf("GET %s answered the policy %q", path, csp)
		}
	}
	if w := request(t, srv, http.MethodGet, "/api/state", "", nil); w.Code != http.StatusOK || !strings.Contains(w.Body.String(), `"phase":"ready"`) {
		t.Errorf("the state with the token answered %d %s", w.Code, w.Body)
	}
}

// An action is a POST from the pages' own origin with one JSON object of
// its fields, no larger than maxBody; anything else reaches no session.
func TestServerTakesActionsFromThePagesAlone(t *testing.T) {
	f := &fakeSession{state: State{Phase: PhaseReady}}
	srv := NewServer(f, testToken, testPort)
	const start = `{}`
	for _, c := range []struct {
		name   string
		method string
		body   string
		edit   func(*http.Request)
		want   int
	}{
		{"no origin", http.MethodPost, start, func(r *http.Request) { r.Header.Del("Origin") }, http.StatusForbidden},
		{"another origin", http.MethodPost, start, func(r *http.Request) { r.Header.Set("Origin", "http://evil.example") }, http.StatusForbidden},
		{"another port's origin", http.MethodPost, start, func(r *http.Request) { r.Header.Set("Origin", "http://127.0.0.1:4322") }, http.StatusForbidden},
		{"an opaque origin", http.MethodPost, start, func(r *http.Request) { r.Header.Set("Origin", "null") }, http.StatusForbidden},
		{"a form", http.MethodPost, start, func(r *http.Request) { r.Header.Set("Content-Type", "application/x-www-form-urlencoded") }, http.StatusUnsupportedMediaType},
		{"plain text", http.MethodPost, start, func(r *http.Request) { r.Header.Set("Content-Type", "text/plain") }, http.StatusUnsupportedMediaType},
		{"an unknown field", http.MethodPost, `{"admin":"me@example.com"}`, nil, http.StatusBadRequest},
		{"a mode", http.MethodPost, `{"mode":"tailnet"}`, nil, http.StatusBadRequest},
		{"two objects", http.MethodPost, start + start, nil, http.StatusBadRequest},
		{"too large", http.MethodPost, `{"offer":"` + strings.Repeat("a", maxBody) + `"}`, nil, http.StatusBadRequest},
		{"a GET", http.MethodGet, "", nil, http.StatusMethodNotAllowed},
	} {
		t.Run(c.name, func(t *testing.T) {
			if w := request(t, srv, c.method, "/api/start", c.body, c.edit); w.Code != c.want {
				t.Errorf("answered %d %s, want %d", w.Code, w.Body, c.want)
			}
		})
	}
	if calls := f.called(); len(calls) != 0 {
		t.Fatalf("refused requests reached the session: %v", calls)
	}
	if w := request(t, srv, http.MethodPost, "/api/state", "{}", nil); w.Code != http.StatusMethodNotAllowed {
		t.Errorf("a POST of the state answered %d", w.Code)
	}
	if w := request(t, srv, http.MethodPost, "/", "{}", nil); w.Code != http.StatusMethodNotAllowed {
		t.Errorf("a POST of the page answered %d", w.Code)
	}
	for _, path := range []string{"/api/nothing", "/api/check", "/api/name", "/api/cancel"} {
		if w := request(t, srv, http.MethodPost, path, "{}", nil); w.Code != http.StatusNotFound {
			t.Errorf("the unknown action %s answered %d", path, w.Code)
		}
	}
	for path, want := range map[string]string{
		"/api/start":  start,
		"/api/choose": `{"offer":"retry"}`,
	} {
		if w := request(t, srv, http.MethodPost, path, want, func(r *http.Request) { r.Header.Set("Origin", "http://localhost:4321") }); w.Code != http.StatusOK {
			t.Errorf("POST %s answered %d %s", path, w.Code, w.Body)
		}
	}
	got := strings.Join(f.called(), "\n")
	for _, want := range []string{"start", "choose retry"} {
		if !strings.Contains(got, want) {
			t.Errorf("the session was not asked %q:\n%s", want, got)
		}
	}
}

// A session's refusal is its sentence, 422; one the phase does not take
// is 409.
func TestServerAnswersRefusalsWithTheirSentence(t *testing.T) {
	f := &fakeSession{state: State{Phase: PhaseReady}}
	srv := NewServer(f, testToken, testPort)
	f.set(State{Phase: PhaseReady}, errors.New(".env says CYFR is reached as local"))
	w := request(t, srv, http.MethodPost, "/api/start", `{}`, nil)
	var body map[string]string
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil || w.Code != http.StatusUnprocessableEntity || body["sentence"] != ".env says CYFR is reached as local" {
		t.Errorf("a refusal answered %d %s", w.Code, w.Body)
	}
	f.set(State{Phase: PhaseRunning}, fmt.Errorf("%w: \"retry\" is not offered", ErrNotNow))
	if w := request(t, srv, http.MethodPost, "/api/choose", `{"offer":"retry"}`, nil); w.Code != http.StatusConflict || !strings.Contains(w.Body.String(), "is not offered") {
		t.Errorf("a request the phase does not take answered %d %s", w.Code, w.Body)
	}
}

// A done run's setup link reaches the pages as setup_url, beside the
// address.
func TestServerAnswersTheSetupLink(t *testing.T) {
	const link = "http://localhost:4000/setup#" + testToken
	f := &fakeSession{state: State{Phase: PhaseDone, Address: "http://localhost:4000", SetupURL: link}}
	w := request(t, NewServer(f, testToken, testPort), http.MethodGet, "/api/state", "", nil)
	var got map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil || w.Code != http.StatusOK {
		t.Fatalf("the state answered %d %s (%v)", w.Code, w.Body, err)
	}
	if got["setup_url"] != link || got["address"] != "http://localhost:4000" {
		t.Errorf("the state answered %v, want the setup link %q", got, link)
	}
}

// The run's end is marked read once a page has read a done or failed
// state, and not before.
func TestServerMarksTheEndRead(t *testing.T) {
	for _, end := range []string{PhaseDone, PhaseFailed} {
		f := &fakeSession{state: State{Phase: PhaseRunning}}
		srv := NewServer(f, testToken, testPort)
		request(t, srv, http.MethodGet, "/api/state", "", nil)
		f.set(State{Phase: end}, nil)
		request(t, srv, http.MethodGet, "/api/state", "", func(r *http.Request) { r.Header.Del(tokenHeader) })
		select {
		case <-srv.Final():
			t.Fatalf("the end (%s) was marked read before a page read it", end)
		default:
		}
		request(t, srv, http.MethodGet, "/api/state", "", nil)
		select {
		case <-srv.Final():
		default:
			t.Errorf("the end (%s) read was not marked", end)
		}
		request(t, srv, http.MethodGet, "/api/state", "", nil)
	}
}

// The pages load nothing from the network: every file the server serves
// names no scheme, and the stylesheet imports nothing.
func TestPagesNeedNoNetwork(t *testing.T) {
	err := fs.WalkDir(assets, "assets", func(path string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() || strings.HasSuffix(path, ".png") {
			return err
		}
		data, err := assets.ReadFile(path)
		if err != nil {
			return err
		}
		text := string(data)
		for _, bad := range []string{"http:", "https:", "url(", "@import", "//cdn", "src=\"//", "href=\"//"} {
			if strings.Contains(text, bad) {
				t.Errorf("%s holds %q", path, bad)
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	for _, page := range pages {
		if _, err := assets.ReadFile(page.file); err != nil {
			t.Errorf("the served file %s is not embedded: %v", page.file, err)
		}
	}
}

// The pages ask nothing, as cyfr init asks nothing: no field to type in,
// no choice beside the start, the retry and the setup link's buttons.
func TestPagesAskNothing(t *testing.T) {
	page, err := assets.ReadFile("assets/index.html")
	if err != nil {
		t.Fatal(err)
	}
	for _, asked := range []string{"<input", "<select", "<textarea", "data-mode", "data-go", "tailnet", "Tailscale"} {
		if strings.Contains(string(page), asked) {
			t.Errorf("the pages hold %q", asked)
		}
	}
}

// The listener binds IPv4 loopback alone, a free port for 0, and the
// address it prints carries the token in its fragment, which no request
// sends.
func TestListenBindsLoopbackAlone(t *testing.T) {
	l, err := Listen(0)
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	addr := l.Addr().(*net.TCPAddr)
	if !addr.IP.Equal(net.IPv4(127, 0, 0, 1)) || addr.Port == 0 {
		t.Errorf("the listener is on %s", addr)
	}
	if got, want := Address(l, testToken), fmt.Sprintf("http://127.0.0.1:%d/#%s", addr.Port, testToken); got != want {
		t.Errorf("the address is %q, want %q", got, want)
	}
	srv := httptest.NewUnstartedServer(NewServer(&fakeSession{state: State{Phase: PhaseReady}}, testToken, addr.Port))
	srv.Listener.Close()
	srv.Listener = l
	srv.Start()
	defer srv.Close()
	res, err := http.Get(fmt.Sprintf("http://127.0.0.1:%d/", addr.Port))
	if err != nil {
		t.Fatal(err)
	}
	page, _ := io.ReadAll(res.Body)
	res.Body.Close()
	if res.StatusCode != http.StatusOK || !strings.Contains(string(page), "Welcome to CYFR") {
		t.Errorf("the page answered %d", res.StatusCode)
	}
}

// NewToken is 32 random bytes in hexadecimal, another each time.
func TestNewToken(t *testing.T) {
	a, err := NewToken()
	if err != nil {
		t.Fatal(err)
	}
	b, _ := NewToken()
	if len(a) != 64 || strings.Trim(a, "0123456789abcdef") != "" || a == b {
		t.Errorf("tokens %q and %q", a, b)
	}
}
