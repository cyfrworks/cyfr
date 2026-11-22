// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"cmp"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"

	"github.com/cyfr/codex/internal/access"
	"github.com/cyfr/codex/internal/account/accounttest"
	"github.com/cyfr/codex/internal/desktop"
	"github.com/cyfr/codex/internal/disk"
	"github.com/cyfr/codex/internal/shell"
)

var (
	pageProof = regexp.MustCompile(`data-proof="([^"]+)"`)
	pageCode  = regexp.MustCompile(`<p class="code">([^<]+)</p>`)
	testToken = strings.Repeat("ab", 32)
)

const (
	logNotSetUp = "[Cyfr] Not set up: no one is set up on this CYFR yet.\n"
	logSetUp    = "[Cyfr] Set up: this CYFR has its first person.\n"
	startedAt   = "2026-10-28T00:01:02.123456789Z"
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

func (a *localApp) page() string {
	r := httptest.NewRequest(http.MethodGet, shell.Origin+"/", nil)
	r.Host = shell.Listen
	w := httptest.NewRecorder()
	a.ServeHTTP(w, r)
	return w.Body.String()
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

// open presses Connect at typed and takes it to the device's pages.
func (a *localApp) open(typed, home string) {
	a.t.Helper()
	done := make(chan chooserAnswer, 1)
	go func() { done <- a.chooser("/bootstrap/connect", map[string]string{"address": typed}) }()
	select {
	case m := <-a.sent:
		if m != (desktop.Message{Type: desktop.TypeHome, Home: home, Account: home}) {
			a.t.Fatalf("main heard %+v", m)
		}
	case got := <-done:
		a.t.Fatalf("Connect answered %+v and main heard nothing", got)
	case <-time.After(20 * time.Second):
		a.t.Fatal("Connect said nothing to main")
	}
	a.HomeReady(home)
	if got := <-done; got.Next != "/" {
		a.t.Fatalf("Connect answered %+v", got)
	}
}

// refused presses Connect at home and wants it refused with words, main
// told nothing.
func (a *localApp) refused(home, words string) {
	a.t.Helper()
	got := make(chan chooserAnswer, 1)
	go func() { got <- a.chooser("/bootstrap/connect", map[string]string{"address": home}) }()
	select {
	case m := <-a.sent:
		a.t.Fatalf("main heard %+v", m)
	case answer := <-got:
		if answer.Next != "" || !strings.Contains(answer.Error, words) {
			a.t.Fatalf("Connect answered %+v, want %q", answer, words)
		}
	case <-time.After(20 * time.Second):
		a.t.Fatal("Connect did not answer")
	}
}

// makeAccount makes the device's account and goes on to its first
// connection, answering the passphrase that unlocks it.
func (a *localApp) makeAccount() string {
	a.t.Helper()
	drawn := pageCode.FindStringSubmatch(a.form("/passphrase", nil))
	if drawn == nil {
		a.t.Fatal("no passphrase was drawn")
	}
	page := a.form("/setup", url.Values{"name": {"alice"}, "secret": {drawn[1]}, "again": {drawn[1]}})
	proof := pageProof.FindStringSubmatch(page)
	if proof == nil {
		a.t.Fatalf("setup reached no recovery code:\n%s", page)
	}
	a.form("/saved", url.Values{"proof": {proof[1]}})
	return drawn[1]
}

// listening is a program on this computer's loopback: what reached it,
// connections and requests.
type listening struct {
	srv    *httptest.Server
	port   int
	mu     sync.Mutex
	conns  int
	asked  []string
	hellos chan map[string]any
}

func (l *listening) reached() (conns, requests int) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.conns, len(l.asked)
}

func newListening(t *testing.T, handler http.Handler) *listening {
	t.Helper()
	l := &listening{hellos: make(chan map[string]any, 8)}
	l.srv = httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		l.mu.Lock()
		l.asked = append(l.asked, r.Host+r.URL.Path)
		l.mu.Unlock()
		if r.URL.Path != "/device/websocket" {
			handler.ServeHTTP(w, r)
			return
		}
		conn, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		var hello map[string]any
		if _, raw, err := conn.Read(r.Context()); err == nil && json.Unmarshal(raw, &hello) == nil {
			l.hellos <- hello
		}
		_ = conn.Close(4401, "unauthenticated")
	}))
	l.srv.Config.ConnState = func(_ net.Conn, s http.ConnState) {
		if s == http.StateNew {
			l.mu.Lock()
			l.conns++
			l.mu.Unlock()
		}
	}
	l.srv.Start()
	t.Cleanup(l.srv.Close)
	u, err := url.Parse(l.srv.URL)
	if err != nil {
		t.Fatal(err)
	}
	if l.port, err = strconv.Atoi(u.Port()); err != nil {
		t.Fatal(err)
	}
	return l
}

// servingAccounts is a CYFR on loopback serving its own accounts at home
// (its address when that is "").
func servingAccounts(t *testing.T, home string) *listening {
	t.Helper()
	accounts := accounttest.New(t)
	raw, err := url.Parse(accounts.URL())
	if err != nil {
		t.Fatal(err)
	}
	l := newListening(t, httputil.NewSingleHostReverseProxy(raw))
	accounts.ServedAt(cmp.Or(home, "http://localhost:"+strconv.Itoa(l.port)))
	return l
}

// folderDocker answers in this process from the scenario's files. A
// connection asks Docker several times, and a program started for each
// call is this test binary again, about a second each under the race
// detector.
type folderDocker struct{ s *updateScenario }

func (d folderDocker) Run(ctx context.Context, c access.Call) (access.Result, error) {
	if err := ctx.Err(); err != nil {
		return access.Result{}, err
	}
	s := d.s
	s.engine.mu.Lock()
	s.engine.calls = append(s.engine.calls, c)
	s.engine.mu.Unlock()
	f, err := os.OpenFile(filepath.Join(s.fake, "log"), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return access.Result{}, err
	}
	_, err = f.WriteString(strings.Join(c.Args, " ") + "\n")
	if err := errors.Join(err, f.Close()); err != nil {
		return access.Result{}, err
	}
	key := c.Args[0]
	if key == "ps" {
		key = "cyfrps"
	}
	var res access.Result
	if out, err := os.ReadFile(filepath.Join(s.fake, key+".out")); err == nil {
		res.Stdout = out
	}
	if exit, err := os.ReadFile(filepath.Join(s.fake, key+".exit")); err == nil {
		if res.ExitCode, err = strconv.Atoi(strings.TrimSpace(string(exit))); err != nil {
			return res, err
		}
	}
	return res, nil
}

// answeredEngine is the scenario's fake engine over folderDocker.
type answeredEngine struct {
	stackEngine
	docker access.Docker
}

func (e answeredEngine) Docker() access.Docker { return e.docker }

func answeredHere(s *updateScenario) {
	opened := openEngine
	s.t.Cleanup(func() { openEngine = opened })
	openEngine = func(dir string) (stackEngine, error) {
		e, err := opened(dir)
		if err != nil {
			return nil, err
		}
		return answeredEngine{e, folderDocker{s}}, nil
	}
}

// localStack is a folder with what Docker says of it.
type localStack struct {
	*updateScenario
}

func newLocalStack(t *testing.T) localStack {
	t.Helper()
	standInMachine(t)
	s := newUpdateScenario(t, shippedCompose(t), nil)
	answeredHere(s)
	s.answer("context.out", "unix:///var/run/docker.sock\n")
	s.answer("cyfrps.out", "")
	s.answer("logs.out", "booting\n"+logNotSetUp)
	return localStack{s}
}

// env writes the folder's .env: local at port, the accounts its own, with
// the setup token and extra.
func (s localStack) env(port int, extra ...string) {
	s.t.Helper()
	home := "http://localhost"
	if port != 80 {
		home += ":" + strconv.Itoa(port)
	}
	text := "CYFR_ACCESS=local\nCYFR_PORT=" + strconv.Itoa(port) + "\nCYFR_LOCUS_BUILDS_URL=\n" +
		"CYFR_DIRECTORY_URL=" + home + "\n" + setupTokenVar + "=" + testToken + "\n" + strings.Join(extra, "")
	if err := os.WriteFile(filepath.Join(s.project, ".env"), []byte(text), 0o600); err != nil {
		s.t.Fatal(err)
	}
}

// runs has Docker say container id of the folder at dir runs publishing
// ports on loopback, changed by change.
func (s localStack) runs(id, dir string, change func(map[string]any), ports ...int) {
	s.t.Helper()
	published := map[string]any{}
	for _, p := range ports {
		published[strconv.Itoa(p)+"/tcp"] = []map[string]string{{"HostIp": "127.0.0.1", "HostPort": strconv.Itoa(p)}}
	}
	c := map[string]any{"id": id, "running": true, "paused": false, "restarting": false, "started": startedAt, "dir": dir, "ports": published}
	if change != nil {
		change(c)
	}
	raw, err := json.Marshal(c)
	if err != nil {
		s.t.Fatal(err)
	}
	s.answer("cyfrps.out", id+"\n")
	s.answer("inspect.out", string(raw)+"\n")
}

func (s localStack) stopped() { s.answer("cyfrps.out", "") }

// standInDial has every connection made to at reach l instead, recording
// what each was made to; then runs once it is made.
func standInDial(t *testing.T, at string, l *listening, then func()) *[]string {
	t.Helper()
	saved := dialTCP
	t.Cleanup(func() { dialTCP = saved })
	var mu sync.Mutex
	var dialled []string
	dialTCP = func(ctx context.Context, network, address string) (net.Conn, error) {
		mu.Lock()
		dialled = append(dialled, address)
		mu.Unlock()
		if address == at && l != nil {
			address = "127.0.0.1:" + strconv.Itoa(l.port)
		}
		conn, err := saved(ctx, network, address)
		if err == nil && then != nil {
			then()
		}
		return conn, err
	}
	return &dialled
}

func helloOf(t *testing.T, l *listening) map[string]any {
	t.Helper()
	select {
	case hello := <-l.hellos:
		return hello
	case <-time.After(20 * time.Second):
		t.Fatal("the CYFR heard no hello")
	}
	return nil
}

func noHello(t *testing.T, l *listening, who string) {
	t.Helper()
	select {
	case hello := <-l.hellos:
		t.Fatalf("%s was sent a hello, admission %v", who, hello["admission"])
	default:
	}
}

// The app opens the CYFR of the folder remembered, wherever cyfr's working
// directory is and whatever its environment says, by one reading of the
// folder's own .env: its address, and its account service, here the CYFR's
// own origin. The device's first hello brings the setup token only while
// that container's log says no one is set up, and no start is asked of the
// engine.
func TestTheAppOpensTheRememberedFoldersCYFR(t *testing.T) {
	for _, c := range []struct {
		name, log, exit string
		busy            bool
		carries         bool
	}{
		{"no one set up", "booting\n" + logNotSetUp, "0", false, true},
		{"someone set up", logNotSetUp + logSetUp, "0", false, false},
		{"set up at the boot", "booting\n", "0", false, false},
		{"a log unread", logNotSetUp, "1", false, false},
		{"another command holds the lock", logNotSetUp, "0", true, false},
	} {
		t.Run(c.name, func(t *testing.T) {
			s := newLocalStack(t)
			cyfr := servingAccounts(t, "")
			s.env(cyfr.port)
			s.runs("c0ffee", s.project, nil, cyfr.port)
			s.answer("logs.out", c.log)
			s.answer("logs.exit", c.exit)
			t.Setenv(directoryVar, "https://launcher.example")
			t.Setenv(setupTokenVar, strings.Repeat("cd", 32))
			t.Setenv("CYFR_PORT", "4999")

			home := "http://localhost:" + strconv.Itoa(cyfr.port)
			a := newLocalApp(t, s.project)
			if got := a.chooser("/bootstrap/state", nil); got.Home != home || got.Next != "" || got.Error != "" {
				t.Fatalf("the chooser shows %+v", got)
			}
			if s.engine.locks != 0 || len(s.engine.calls) != 0 {
				t.Fatalf("showing the folder took the lock %d times or called docker %v", s.engine.locks, s.engine.calls)
			}
			a.open(home, home)
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
			a.makeAccount()
			admission, _ := helloOf(t, cyfr)["admission"].(map[string]any)
			if got, carried := admission["setup"]; carried != c.carries || carried && got != testToken {
				t.Fatalf("the first hello's admission is %v", admission)
			}
			if c.carries && !slices.Contains(s.log(), "logs --since "+startedAt+" c0ffee") {
				t.Fatalf("setup was not read from that container since its start: %v", s.log())
			}
			if s.engine.starts != 0 {
				t.Fatalf("the app started the CYFR %d times", s.engine.starts)
			}
		})
	}
}

// Whether the folder's CYFR runs is Docker's word. Any other program on
// its port, one that imitates its health answer too, is not that CYFR: it
// is named as stopped, main is told nothing, nothing is started and not
// one connection reaches the other program.
func TestAStandInOnTheFoldersPortIsNotItsCYFR(t *testing.T) {
	imitation := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, `{"status":"ok","version":"0.6.0"}`)
	})
	namesake := filepath.Join(t.TempDir(), "elsewhere")
	if err := os.MkdirAll(namesake, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, program := range []struct {
		name    string
		handler http.Handler
	}{{"a plain 404", http.NotFoundHandler()}, {"an imitation of the health answer", imitation}} {
		for _, docker := range []struct {
			name, words string
			says        func(s localStack, port int)
		}{
			{"the stack stopped", "is not running", func(localStack, int) {}},
			{"its container exited", "is not running", func(s localStack, port int) {
				s.runs("c0ffee", s.project, func(c map[string]any) { c["running"] = false }, port)
			}},
			{"its container restarting", "is not running", func(s localStack, port int) {
				s.runs("c0ffee", s.project, func(c map[string]any) { c["restarting"] = true }, port)
			}},
			{"its container on another port", "is not running", func(s localStack, port int) { s.runs("c0ffee", s.project, nil, port+1) }},
			{"another folder's container", "is not running", func(s localStack, port int) { s.runs("c0ffee", namesake, nil, port) }},
			{"Docker not answering", "Docker could not say", func(s localStack, _ int) { s.answer("cyfrps.exit", "1") }},
			{"a Docker on another computer", "containers on another computer", func(s localStack, port int) {
				s.runs("c0ffee", s.project, nil, port)
				s.answer("context.out", "tcp://192.0.2.1:2375\n")
			}},
		} {
			t.Run(program.name+", "+docker.name, func(t *testing.T) {
				s := newLocalStack(t)
				other := newListening(t, program.handler)
				s.env(other.port)
				docker.says(s, other.port)
				a := newLocalApp(t, s.project)
				a.refused("http://localhost:"+strconv.Itoa(other.port), docker.words)
				if conns, requests := other.reached(); conns != 0 || requests != 0 {
					t.Fatalf("the other program got %d connections, %d requests", conns, requests)
				}
				if s.engine.starts != 0 || s.engine.locks != 0 {
					t.Fatalf("a stopped CYFR met %d starts, %d locks", s.engine.starts, s.engine.locks)
				}
			})
		}
	}
}

// The container that answered for the port must hold it through the
// connection: gone, replaced or started again while it was made, the
// connection carries nothing.
func TestAConnectionOutlivingItsContainerCarriesNothing(t *testing.T) {
	for name, change := range map[string]func(s localStack, port int){
		"gone":     func(s localStack, _ int) { s.stopped() },
		"replaced": func(s localStack, port int) { s.runs("dec0de", s.project, nil, port) },
		"started again": func(s localStack, port int) {
			s.runs("c0ffee", s.project, func(c map[string]any) { c["started"] = "2026-10-28T00:09:09Z" }, port)
		},
	} {
		t.Run(name, func(t *testing.T) {
			s := newLocalStack(t)
			other := newListening(t, http.NotFoundHandler())
			s.env(other.port)
			s.runs("c0ffee", s.project, nil, other.port)
			standInDial(t, "", nil, func() { change(s, other.port) })
			a := newLocalApp(t, s.project)
			a.refused("http://localhost:"+strconv.Itoa(other.port), "is not running")
			if _, requests := other.reached(); requests != 0 {
				t.Fatalf("%d requests were sent on it", requests)
			}
		})
	}
}

// A retained address never receives a token read for another, nor one read
// when the folder's CYFR no longer runs there: after the open, the folder
// changed or stopped, the next first hello is not sent and nothing more
// reaches the address kept.
func TestARetainedAddressNeverReceivesTheSetupToken(t *testing.T) {
	for _, c := range []struct {
		name, words string
		change      func(s localStack, first, second int)
	}{
		{"the folder's address changed", "changed after it was opened", func(s localStack, _, second int) {
			s.env(second)
			s.runs("dec0de", s.project, nil, second)
		}},
		{"the address changed and the old container still runs", "changed after it was opened", func(s localStack, _, second int) {
			s.env(second)
		}},
		{"the account service changed", "changed after it was opened", func(s localStack, first, _ int) {
			s.env(first, "CYFR_DIRECTORY_URL=https://accounts.example.com\n")
		}},
		{"the stack stopped and another program took the port", "is not running", func(s localStack, _, _ int) { s.stopped() }},
	} {
		t.Run(c.name, func(t *testing.T) {
			s := newLocalStack(t)
			first, second := servingAccounts(t, ""), newListening(t, http.NotFoundHandler())
			s.env(first.port)
			s.runs("c0ffee", s.project, nil, first.port)
			home := "http://localhost:" + strconv.Itoa(first.port)
			a := newLocalApp(t, s.project)
			a.open(home, home)
			passphrase := a.makeAccount()
			helloOf(t, first) // refused by this stand-in, so the next unlock says hello again

			c.change(s, first.port, second.port)
			conns, requests := first.reached()
			a.form("/unlock", url.Values{"secret": {passphrase}})
			noHello(t, first, "the address kept")
			noHello(t, second, "the folder's new address")
			if now, asked := first.reached(); now != conns || asked != requests {
				t.Fatalf("the address kept got %d connections and %d requests more", now-conns, asked-requests)
			}
			if now, _ := second.reached(); now != 0 {
				t.Fatalf("the new address was sent %d connections by a shell of the old", now)
			}
			if page := a.page(); !strings.Contains(page, c.words) {
				t.Fatalf("the page does not say why:\n%s", page)
			}
		})
	}
}

// Sol's reading of the same rule at the reader: a setup token is answered
// only for the address the shell was opened at.
func TestTheSetupTokenIsOnlyForTheAddressRead(t *testing.T) {
	s := newLocalStack(t)
	s.env(4100)
	s.runs("c0ffee", s.project, nil, 4100, 4200)
	l, err := readLocal(s.project, "the test")
	if err != nil || l.Shell.Address != "http://localhost:4100" {
		t.Fatalf("read %+v, %v", l.Shell.Address, err)
	}
	if got := l.Shell.SetupToken(t.Context()); got != testToken {
		t.Fatalf("with the folder as read the token is %q", got)
	}
	s.env(4200)
	if got := l.Shell.SetupToken(t.Context()); got != "" {
		t.Fatal("a shell still at 4100 was given the token of the CYFR at 4200")
	}
}

// A folder on port 80 goes all the way through: the one spelling its CYFR
// signs, in the chooser, at Connect however typed, to main, to the account
// service and in the hello that carries the setup token.
func TestAFolderOnPort80GoesAllTheWayThrough(t *testing.T) {
	const home = "http://localhost"
	for _, typed := range []string{"", "http://localhost:80"} {
		t.Run("typed "+typed, func(t *testing.T) {
			s := newLocalStack(t)
			cyfr := servingAccounts(t, home)
			s.env(80)
			s.runs("c0ffee", s.project, nil, 80)
			dialled := standInDial(t, "127.0.0.1:80", cyfr, nil)
			a := newLocalApp(t, s.project)
			shown := a.chooser("/bootstrap/state", nil)
			if shown.Home != home || shown.Error != "" {
				t.Fatalf("the chooser shows %+v", shown)
			}
			a.open(cmp.Or(typed, shown.Home), home)
			a.makeAccount()
			admission, _ := helloOf(t, cyfr)["admission"].(map[string]any)
			if admission["setup"] != testToken {
				t.Fatalf("the first hello's admission is %v", admission)
			}
			if slices.ContainsFunc(*dialled, func(at string) bool { return at != "127.0.0.1:80" }) {
				t.Fatalf("connected to %v", *dialled)
			}
		})
	}
}

// A local CYFR is reached at 127.0.0.1 alone, where Docker publishes it,
// never at what else localhost resolves to, through no proxy of this
// process's, and its client speaks to no other program on this computer.
func TestTheFoldersClientReachesThatCYFRAlone(t *testing.T) {
	s := newLocalStack(t)
	cyfr, other := newListening(t, http.NotFoundHandler()), newListening(t, http.NotFoundHandler())
	s.env(cyfr.port)
	s.runs("c0ffee", s.project, nil, cyfr.port)
	dialled := standInDial(t, "", nil, nil)
	l, err := readLocal(s.project, "the test")
	if err != nil {
		t.Fatal(err)
	}
	if err := l.Answers(t.Context()); err != nil {
		t.Fatalf("it does not answer: %v", err)
	}
	if want := []string{"127.0.0.1:" + strconv.Itoa(cyfr.port)}; !slices.Equal(*dialled, want) {
		t.Fatalf("connected to %v, want %v", *dialled, want)
	}
	for _, elsewhere := range []string{"127.0.0.1:", "localhost:", "[::1]:"} {
		resp, err := l.Shell.Client.Get("http://" + elsewhere + strconv.Itoa(other.port) + "/")
		if err == nil {
			resp.Body.Close()
			t.Errorf("%s was reached", elsewhere)
		}
	}
	if conns, _ := other.reached(); conns != 0 {
		t.Fatalf("another program got %d connections", conns)
	}
	route := l.Shell.Client.Transport.(*http.Transport).Proxy
	if proxy, err := route(httptest.NewRequest(http.MethodGet, l.Shell.Address+"/", nil)); proxy != nil || err != nil {
		t.Fatalf("the CYFR is reached through %v (%v)", proxy, err)
	}
}

// A public CYFR's address takes no proxy of the environment either, which
// is this computer's way to everywhere else alone.
func TestAFoldersOwnAddressTakesNoProxyOfTheEnvironment(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, ".env"), []byte(scenarioEnv), 0o600); err != nil {
		t.Fatal(err)
	}
	proxy := &url.URL{Scheme: "http", Host: "proxy.example:3128"}
	saved := computersProxy
	t.Cleanup(func() { computersProxy = saved })
	computersProxy = func(*http.Request) (*url.URL, error) { return proxy, nil }
	l, err := readLocal(dir, "the test")
	if err != nil {
		t.Fatal(err)
	}
	route := l.Shell.Client.Transport.(*http.Transport).Proxy
	if got, err := route(httptest.NewRequest(http.MethodGet, "https://cyfr.example.com/", nil)); got != nil || err != nil {
		t.Fatalf("the CYFR is reached through %v (%v)", got, err)
	}
	if got, err := route(httptest.NewRequest(http.MethodGet, "https://cyfr.run/", nil)); got != proxy || err != nil {
		t.Fatalf("cyfr.run is reached through %v (%v), not this computer's way", got, err)
	}
}

// A folder with tailnet access is reached through its SOCKS5 proxy, by cyfr
// and by the app's engine both, and only while Docker says both its
// containers publish.
func TestALocalCYFROnItsTailnetIsReachedThroughItsProxy(t *testing.T) {
	s := newLocalStack(t)
	env := "CYFR_ACCESS=tailnet\nCYFR_HOST=box.tail1234.ts.net\nCYFR_PUBLIC_URL=https://box.tail1234.ts.net\n" +
		"CYFR_TAILNET_NODE_ID=nAAAAAAAAACNTRL\nCYFR_LOCUS_BUILDS_URL=\nCYFR_PORT=4000\n"
	if err := os.WriteFile(filepath.Join(s.project, ".env"), []byte(env), 0o600); err != nil {
		t.Fatal(err)
	}
	s.runs("c0ffee", s.project, nil, 4000) // and no proxy of its own
	other := newListening(t, http.NotFoundHandler())
	dialled := standInDial(t, "127.0.0.1:1055", other, nil)
	l, err := readLocal(s.project, "the CYFR app")
	if err != nil {
		t.Fatal(err)
	}
	if l.Shell.Address != "https://box.tail1234.ts.net" || l.Proxy != "socks5://127.0.0.1:1055" ||
		l.Resolver != "MAP * ~NOTFOUND, EXCLUDE 127.0.0.1" {
		t.Fatalf("read %s by %q, %q", l.Shell.Address, l.Proxy, l.Resolver)
	}
	r := httptest.NewRequest(http.MethodGet, l.Shell.Address, nil)
	if proxy, err := l.Shell.Client.Transport.(*http.Transport).Proxy(r); err != nil || proxy == nil || proxy.String() != l.Proxy {
		t.Fatalf("cyfr reaches it through %v (%v)", proxy, err)
	}
	if err := l.Answers(t.Context()); err == nil || !strings.Contains(err.Error(), "is not running") || len(*dialled) != 0 {
		t.Fatalf("a program on the proxy's port was taken for it: %v, %v", err, *dialled)
	}
}
