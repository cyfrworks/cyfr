// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"

	"github.com/cyfr/codex/internal/account/accounttest"
	"github.com/cyfr/codex/internal/desktop"
	"github.com/cyfr/codex/internal/disk"
	"github.com/cyfr/codex/internal/shell"
)

var (
	pageProof = regexp.MustCompile(`data-proof="([^"]+)"`)
	pageCode  = regexp.MustCompile(`<p class="code">([^<]+)</p>`)
)

// localApp is desktop-serve's service over a folder set up on this
// computer, remembered, the working directory elsewhere: what it says to
// main, and its requests as the app's pages send them.
type localApp struct {
	*desktop.Service
	t    *testing.T
	sent chan desktop.Message
}

func newLocalApp(t *testing.T, project string) *localApp {
	t.Helper()
	a := &localApp{t: t, sent: make(chan desktop.Message, 16)}
	a.Service = newDesktopService(t.TempDir(), func(m desktop.Message) error { a.sent <- m; return nil })
	a.AccountRoad = false
	a.Shell = func(c *shell.Config) {
		c.Chip = func() bool { return false }
		c.Detect = func(string) disk.Report { return disk.Report{Root: disk.Unknown, Data: disk.Unknown} }
	}
	if err := a.Clients.SelectProject(project); err != nil {
		t.Fatal(err)
	}
	t.Chdir(t.TempDir())
	t.Cleanup(func() { a.Lock("") })
	return a
}

func (a *localApp) post(path, kind, body string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(http.MethodPost, shell.Origin+path, strings.NewReader(body))
	r.Host = shell.Listen
	r.Header.Set("Origin", shell.Origin)
	r.Header.Set("Content-Type", kind)
	w := httptest.NewRecorder()
	a.ServeHTTP(w, r)
	return w
}

type chooserAnswer struct{ Home, Next, Error string }

func (a *localApp) chooser(path string, fields map[string]string) chooserAnswer {
	a.t.Helper()
	body := map[string]string{"token": a.Token}
	for k, v := range fields {
		body[k] = v
	}
	raw, _ := json.Marshal(body)
	var got chooserAnswer
	if w := a.post(path, "application/json", string(raw)); w.Code != http.StatusOK || json.Unmarshal(w.Body.Bytes(), &got) != nil {
		a.t.Errorf("%s answered %d %s", path, w.Code, w.Body)
	}
	return got
}

func (a *localApp) form(path string, fields url.Values) string {
	return a.post(path, "application/x-www-form-urlencoded", fields.Encode()).Body.String()
}

// The app opens the CYFR of the folder remembered, wherever cyfr's working
// directory is, by the folder's own .env: its address, and its account
// service, here the CYFR's own origin. The device's first hello brings the
// setup token only while cyfr's log in that folder says no one is set up,
// and no start is asked of the engine.
func TestTheAppOpensTheRememberedFoldersCYFR(t *testing.T) {
	const notSetUp = "[Cyfr] Not set up: no one is set up on this CYFR yet.\n"
	const setUp = "[Cyfr] Set up: this CYFR has its first person.\n"
	token := strings.Repeat("ab", 32)
	for _, c := range []struct {
		name, log string
		busy      bool
		carries   bool
	}{
		{"no one set up", "booting\n" + notSetUp, false, true},
		{"someone set up", notSetUp + setUp, false, false},
		{"another command holds the lock", notSetUp, true, false},
	} {
		t.Run(c.name, func(t *testing.T) {
			standInMachine(t)
			t.Setenv(directoryVar, "")
			s := newUpdateScenario(t, shippedCompose(t), nil)
			dockerStandIn(t, s.fake)
			s.answer("ps.out", "c0ffee\n")
			s.answer("inspect.out", "2026-10-28T00:01:02.123456789Z\n")
			s.answer("logs.out", c.log)
			s.answer("logs.exit", "0")

			accounts := accounttest.New(t)
			at, err := url.Parse(accounts.URL())
			if err != nil {
				t.Fatal(err)
			}
			hellos := make(chan map[string]any, 4)
			mux := http.NewServeMux()
			mux.Handle("/", httputil.NewSingleHostReverseProxy(at))
			mux.HandleFunc("/device/websocket", func(w http.ResponseWriter, r *http.Request) {
				conn, err := websocket.Accept(w, r, nil)
				if err != nil {
					return
				}
				var hello map[string]any
				if _, raw, err := conn.Read(r.Context()); err == nil && json.Unmarshal(raw, &hello) == nil {
					hellos <- hello
				}
				_ = conn.Close(4401, "unauthenticated")
			})
			cyfr := httptest.NewServer(mux)
			t.Cleanup(cyfr.Close)
			bound, err := url.Parse(cyfr.URL)
			if err != nil {
				t.Fatal(err)
			}
			port, err := strconv.Atoi(bound.Port())
			if err != nil {
				t.Fatal(err)
			}
			home := "http://localhost:" + strconv.Itoa(port)
			env := "CYFR_ACCESS=local\nCYFR_PORT=" + strconv.Itoa(port) + "\nCYFR_LOCUS_BUILDS_URL=\n" +
				"CYFR_DIRECTORY_URL=" + home + "\n" + setupTokenVar + "=" + token + "\n"
			if err := os.WriteFile(filepath.Join(s.project, ".env"), []byte(env), 0o600); err != nil {
				t.Fatal(err)
			}

			a := newLocalApp(t, s.project)
			if got := a.chooser("/bootstrap/state", nil); got.Home != home || got.Next != "" || got.Error != "" {
				t.Fatalf("the chooser shows %+v", got)
			}
			if s.engine.locks != 0 || len(s.engine.calls) != 0 {
				t.Fatalf("showing the folder took the lock %d times or called docker %v", s.engine.locks, s.engine.calls)
			}
			done := make(chan chooserAnswer, 1)
			go func() { done <- a.chooser("/bootstrap/connect", map[string]string{"address": home}) }()
			select {
			case m := <-a.sent:
				if m != (desktop.Message{Type: desktop.TypeHome, Home: home, Account: home}) {
					t.Fatalf("main heard %+v", m)
				}
			case got := <-done:
				t.Fatalf("Connect answered %+v and main heard nothing", got)
			case <-time.After(10 * time.Second):
				t.Fatal("Connect said nothing to main")
			}
			a.HomeReady(home)
			if got := <-done; got.Next != "/" {
				t.Fatalf("Connect answered %+v", got)
			}

			drawn := pageCode.FindStringSubmatch(a.form("/passphrase", nil))
			if drawn == nil {
				t.Fatal("no passphrase was drawn")
			}
			page := a.form("/setup", url.Values{"name": {"alice"}, "secret": {drawn[1]}, "again": {drawn[1]}})
			proof := pageProof.FindStringSubmatch(page)
			if proof == nil {
				t.Fatalf("setup reached no recovery code:\n%s", page)
			}
			if c.busy {
				e, err := openEngine(s.project)
				if err != nil {
					t.Fatal(err)
				}
				unlock, err := e.Lock("access tailnet")
				if err != nil {
					t.Fatal(err)
				}
				defer unlock()
			}
			a.form("/saved", url.Values{"proof": {proof[1]}})
			ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
			defer cancel()
			select {
			case hello := <-hellos:
				admission, _ := hello["admission"].(map[string]any)
				if got, carried := admission["setup"]; carried != c.carries || carried && got != token {
					t.Fatalf("the first hello's admission is %v", admission)
				}
			case <-ctx.Done():
				t.Fatal("the CYFR heard no hello")
			}
			if s.engine.starts != 0 {
				t.Fatalf("the app started the CYFR %d times", s.engine.starts)
			}
		})
	}
}

// A folder's CYFR that is stopped is named and never started: no lock, no
// docker call, nothing said to main.
func TestTheAppNeverStartsAStoppedLocalCYFR(t *testing.T) {
	standInMachine(t)
	t.Setenv(directoryVar, "")
	s := newUpdateScenario(t, shippedCompose(t), nil)
	nothing := httptest.NewServer(http.NotFoundHandler())
	gone, err := url.Parse(nothing.URL)
	if err != nil {
		t.Fatal(err)
	}
	nothing.Close()
	env := "CYFR_ACCESS=local\nCYFR_PORT=" + gone.Port() + "\nCYFR_LOCUS_BUILDS_URL=\n"
	if err := os.WriteFile(filepath.Join(s.project, ".env"), []byte(env), 0o600); err != nil {
		t.Fatal(err)
	}
	a := newLocalApp(t, s.project)
	home := "http://localhost:" + gone.Port()
	got := a.chooser("/bootstrap/connect", map[string]string{"address": home})
	if got.Next != "" || !strings.Contains(got.Error, s.project+" does not answer at "+home) {
		t.Fatalf("Connect answered %+v", got)
	}
	select {
	case m := <-a.sent:
		t.Fatalf("main heard %+v", m)
	default:
	}
	if s.engine.starts != 0 || s.engine.locks != 0 || len(s.engine.calls) != 0 {
		t.Fatalf("a stopped CYFR met %d starts, %d locks and %v", s.engine.starts, s.engine.locks, s.engine.calls)
	}
}

// A folder with tailnet access is reached through its SOCKS5 proxy, by cyfr
// and by the app's engine both.
func TestALocalCYFROnItsTailnetIsReachedThroughItsProxy(t *testing.T) {
	useFakeEngine(t)
	t.Setenv(directoryVar, "")
	dir := t.TempDir()
	env := "CYFR_ACCESS=tailnet\nCYFR_HOST=box.tail1234.ts.net\nCYFR_PUBLIC_URL=https://box.tail1234.ts.net\n" +
		"CYFR_TAILNET_NODE_ID=nAAAAAAAAACNTRL\nCYFR_LOCUS_BUILDS_URL=\nCYFR_PORT=4000\n"
	if err := os.WriteFile(filepath.Join(dir, ".env"), []byte(env), 0o600); err != nil {
		t.Fatal(err)
	}
	l, err := readLocal(dir, "the CYFR app")
	if err != nil {
		t.Fatal(err)
	}
	if l.Shell.Address != "https://box.tail1234.ts.net" || l.Proxy != "socks5://127.0.0.1:1055" ||
		l.Resolver != "MAP * ~NOTFOUND, EXCLUDE 127.0.0.1" {
		t.Fatalf("read %s by %q, %q", l.Shell.Address, l.Proxy, l.Resolver)
	}
	r := httptest.NewRequest(http.MethodGet, l.Shell.Address, nil)
	through, ok := l.Shell.Client.Transport.(*http.Transport)
	if !ok {
		t.Fatal("cyfr reaches it with no proxy")
	}
	if proxy, err := through.Proxy(r); err != nil || proxy.String() != l.Proxy {
		t.Fatalf("cyfr reaches it through %v (%v)", proxy, err)
	}
}
