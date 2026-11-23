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
	"runtime"
	"slices"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"

	"github.com/cyfr/codex/internal/access"
	"github.com/cyfr/codex/internal/account"
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
	// proposed counts the attempts open heard.
	proposed uint64
}

func newLocalApp(t *testing.T, project string) *localApp {
	t.Helper()
	a := &localApp{t: t, sent: make(chan desktop.Message, 16)}
	a.Service = newDesktopService(t.TempDir(), func(m desktop.Message) error { a.sent <- m; return nil })
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
	return pressed(a, path, kind, body)
}

// pressed is a POST as the device's own pages send one.
func pressed(h http.Handler, path, kind, body string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(http.MethodPost, shell.Origin+path, strings.NewReader(body))
	r.Host = shell.Listen
	r.Header.Set("Origin", shell.Origin)
	r.Header.Set("Content-Type", kind)
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
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

// open presses Connect at typed and takes it to the device's pages, main
// told the engine's route there, proxy and resolver, when there is one.
func (a *localApp) open(typed, home string, route ...string) {
	a.t.Helper()
	a.proposed++
	want := desktop.Message{Type: desktop.TypeHome, Home: home, Account: home, Attempt: a.proposed}
	if len(route) == 2 {
		want.Proxy, want.Resolver = route[0], route[1]
	}
	done := make(chan chooserAnswer, 1)
	go func() { done <- a.chooser("/bootstrap/connect", map[string]string{"address": typed}) }()
	select {
	case m := <-a.sent:
		if m != want {
			a.t.Fatalf("main heard %+v", m)
		}
	case got := <-done:
		a.t.Fatalf("Connect answered %+v and main heard nothing", got)
	case <-time.After(20 * time.Second):
		a.t.Fatal("Connect said nothing to main")
	}
	a.HomeReady(home, a.proposed)
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
	return makeAccountOn(a.t, a)
}

// makeAccountOn is makeAccount on the device's pages h serves.
func makeAccountOn(t *testing.T, h http.Handler) string {
	t.Helper()
	form := func(path string, fields url.Values) string {
		return pressed(h, path, "application/x-www-form-urlencoded", fields.Encode()).Body.String()
	}
	drawn := pageCode.FindStringSubmatch(form("/passphrase", nil))
	if drawn == nil {
		t.Fatal("no passphrase was drawn")
	}
	page := form("/setup", url.Values{"name": {"alice"}, "secret": {drawn[1]}, "again": {drawn[1]}})
	proof := pageProof.FindStringSubmatch(page)
	if proof == nil {
		t.Fatalf("setup reached no recovery code:\n%s", page)
	}
	form("/saved", url.Values{"proof": {proof[1]}})
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
	// admitting is the address this CYFR admits a hello at, "" when it
	// refuses each; connects is each client it was then sent a connect by.
	// holds is whether it then gives that client its standing and keeps
	// the channel until the device closes it, refusing whatever it asks.
	admitting string
	holds     bool
	connects  chan map[string]any
}

// admit answers hello as the CYFR named l.admitting does one it takes,
// and hears the connect that follows on the same connection.
func (l *listening) admit(ctx context.Context, conn *websocket.Conn, hello map[string]any) {
	send := func(m map[string]any) bool {
		m["protocol"] = shell.DeviceProtocol
		raw, err := json.Marshal(m)
		return err == nil && conn.Write(ctx, websocket.MessageText, raw) == nil
	}
	read := func() map[string]any {
		var m map[string]any
		if _, raw, err := conn.Read(ctx); err != nil || json.Unmarshal(raw, &m) != nil {
			return nil
		}
		return m
	}
	soon := time.Now().Add(time.Minute).UnixMilli()
	if !send(map[string]any{"type": "sign_in_request", "request": map[string]any{
		"protocol": account.SignInProtocol, "purpose": "sign_in", "audience": l.admitting,
		"challenge": strings.Repeat("A", 43), "expires_at": soon, "return": l.admitting + "/login",
	}}) || read()["type"] != "sign_in_answer" {
		return
	}
	const id, athanor = "pcl_1", "ath_1"
	if !send(map[string]any{"type": "admitted", "client_id": id,
		"standing": map[string]any{"client_id": id, "athanor": athanor, "expires_at": soon},
		"certificate": map[string]any{
			"protocol": shell.CertificateProtocol, "kid": hello["kid"], "client_id": id,
			"identifier": hello["identifier"], "athanor": athanor, "audience": l.admitting, "expires_at": soon,
		}}) {
		return
	}
	if connect := read(); connect["type"] == "connect" {
		l.connects <- connect
		if l.holds && send(map[string]any{"type": "standing"}) {
			for m := read(); m != nil; m = read() {
				if m["type"] == "intent" && !send(map[string]any{"type": "answer", "id": m["id"],
					"error": map[string]any{"class": "unavailable"}}) {
					return
				}
			}
		}
	}
}

func (l *listening) reached() (conns, requests int) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.conns, len(l.asked)
}

func newListening(t *testing.T, handler http.Handler) *listening {
	t.Helper()
	l := &listening{hellos: make(chan map[string]any, 8), connects: make(chan map[string]any, 8)}
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
			if l.admitting != "" {
				l.admit(r.Context(), conn, hello)
			}
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
type folderDocker struct {
	s *updateScenario
	// after runs once Docker answered a call of that verb.
	after map[string]func()
}

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
	if then := d.after[c.Args[0]]; then != nil {
		then()
	}
	return res, nil
}

// answeredEngine is the scenario's fake engine over folderDocker.
type answeredEngine struct {
	stackEngine
	docker access.Docker
}

func (e answeredEngine) Docker() access.Docker { return e.docker }

func answeredHere(s *updateScenario, after map[string]func()) {
	opened := openEngine
	s.t.Cleanup(func() { openEngine = opened })
	openEngine = func(dir string) (stackEngine, error) {
		e, err := opened(dir)
		if err != nil {
			return nil, err
		}
		return answeredEngine{e, folderDocker{s, after}}, nil
	}
}

// localStack is a folder with what Docker says of it.
type localStack struct {
	*updateScenario
	// afterDocker is folderDocker's after.
	afterDocker map[string]func()
}

func newLocalStack(t *testing.T) localStack {
	t.Helper()
	standInMachine(t)
	s := newUpdateScenario(t, shippedCompose(t), nil)
	after := map[string]func(){}
	answeredHere(s, after)
	workHere(t)
	s.answer("context.out", "unix:///var/run/docker.sock\n")
	s.answer("cyfrps.out", "")
	s.answer("logs.out", "booting\n"+logNotSetUp)
	return localStack{s, after}
}

// envReached writes the folder's .env for access mode, public or tailnet,
// with port the one published here and its accounts its own, and answers
// its address.
func (s localStack) envReached(mode string, port int) string {
	s.t.Helper()
	host, more := "cyfr.example.com", ""
	if mode == access.ModeTailnet {
		host, more = "box.tail1234.ts.net", "CYFR_TAILNET_NODE_ID=nAAAAAAAAACNTRL\n"
	}
	home := "https://" + host
	text := "CYFR_ACCESS=" + mode + "\nCYFR_HOST=" + host + "\nCYFR_PUBLIC_URL=" + home + "\n" + more +
		"CYFR_PORT=" + strconv.Itoa(port) + "\nCYFR_LOCUS_BUILDS_URL=\n" +
		"CYFR_DIRECTORY_URL=" + home + "\n" + setupTokenVar + "=" + testToken + "\n"
	if err := os.WriteFile(filepath.Join(s.project, ".env"), []byte(text), 0o600); err != nil {
		s.t.Fatal(err)
	}
	return home
}

// onlyOnThisComputer lets connections be made to at alone, recording what
// each was to be made to, and fails any other where it would leave this
// computer. It stands in for this computer's proxy too, recording whom it
// was asked for.
func onlyOnThisComputer(t *testing.T, at string, proxy *url.URL) (dialled, proxied func() []string) {
	t.Helper()
	savedDial, savedProxy := dialTCP, computersProxy
	t.Cleanup(func() { dialTCP, computersProxy = savedDial, savedProxy })
	var mu sync.Mutex
	var to, asked []string
	dialTCP = func(ctx context.Context, network, address string) (net.Conn, error) {
		mu.Lock()
		to = append(to, address)
		mu.Unlock()
		if address != at {
			return nil, errors.New("the test makes no such connection")
		}
		return savedDial(ctx, network, address)
	}
	computersProxy = func(r *http.Request) (*url.URL, error) {
		mu.Lock()
		asked = append(asked, r.URL.Host)
		mu.Unlock()
		return proxy, nil
	}
	copied := func(of *[]string) func() []string {
		return func() []string {
			mu.Lock()
			defer mu.Unlock()
			return slices.Clone(*of)
		}
	}
	return copied(&to), copied(&asked)
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
			{"the stack stopped", "Docker shows no CYFR of", func(localStack, int) {}},
			{"its container exited", "Docker shows no CYFR of", func(s localStack, port int) {
				s.runs("c0ffee", s.project, func(c map[string]any) { c["running"] = false }, port)
			}},
			{"its container restarting", "Docker shows no CYFR of", func(s localStack, port int) {
				s.runs("c0ffee", s.project, func(c map[string]any) { c["restarting"] = true }, port)
			}},
			{"its container on another port", "Docker shows no CYFR of", func(s localStack, port int) { s.runs("c0ffee", s.project, nil, port+1) }},
			{"another folder's container", "Docker shows no CYFR of", func(s localStack, port int) { s.runs("c0ffee", namesake, nil, port) }},
			{"Docker failing", "(docker ps failed with exit status 1), so nothing was sent to it. Check Docker, then try again.", func(s localStack, _ int) { s.answer("cyfrps.exit", "1") }},
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
	for name, c := range map[string]struct {
		words  string
		change func(s localStack, port int)
	}{
		"gone":     {"Docker shows no CYFR of", func(s localStack, _ int) { s.stopped() }},
		"replaced": {"started again", func(s localStack, port int) { s.runs("dec0de", s.project, nil, port) }},
		"started again": {"started again", func(s localStack, port int) {
			s.runs("c0ffee", s.project, func(c map[string]any) { c["started"] = "2026-10-28T00:09:09Z" }, port)
		}},
	} {
		t.Run(name, func(t *testing.T) {
			s := newLocalStack(t)
			other := newListening(t, http.NotFoundHandler())
			s.env(other.port)
			s.runs("c0ffee", s.project, nil, other.port)
			standInDial(t, "", nil, func() { c.change(s, other.port) })
			a := newLocalApp(t, s.project)
			a.refused("http://localhost:"+strconv.Itoa(other.port), c.words)
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
		{"the stack stopped and another program took the port", "Docker shows no CYFR of", func(s localStack, _, _ int) { s.stopped() }},
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
	if got, _ := l.Shell.SetupToken(t.Context()); got != testToken {
		t.Fatalf("with the folder as read the token is %q", got)
	}
	s.env(4200)
	if got, _ := l.Shell.SetupToken(t.Context()); got != "" {
		t.Fatal("a shell still at 4100 was given the token of the CYFR at 4200")
	}
}

// The container whose log said no one is set up is the one the token may
// be sent to. Replaced, started again or gone once that was read, at the
// same origin, the first hello is not sent: no connection is made when the
// change came before it, and none carries a request when it came while
// the connection was made.
func TestTheTokensConnectionIsTheContainerRead(t *testing.T) {
	for _, c := range []struct {
		name, words string
		change      func(s localStack, port int)
	}{
		{"replaced", "started again", func(s localStack, port int) { s.runs("dec0de", s.project, nil, port) }},
		{"started again", "started again", func(s localStack, port int) {
			s.runs("c0ffee", s.project, func(c map[string]any) { c["started"] = "2026-10-28T00:09:09Z" }, port)
		}},
		{"gone", "Docker shows no CYFR of", func(s localStack, _ int) { s.stopped() }},
	} {
		for _, when := range []string{"before the dial", "during the dial"} {
			t.Run(c.name+" "+when, func(t *testing.T) {
				s := newLocalStack(t)
				cyfr := servingAccounts(t, "")
				s.env(cyfr.port)
				s.runs("c0ffee", s.project, nil, cyfr.port)
				home := "http://localhost:" + strconv.Itoa(cyfr.port)
				var read bool
				var conns, requests int
				standInDial(t, "", nil, func() {
					if read && when == "during the dial" {
						c.change(s, cyfr.port)
					}
				})
				a := newLocalApp(t, s.project)
				a.open(home, home)
				s.afterDocker["logs"] = func() {
					read = true
					conns, requests = cyfr.reached()
					if when == "before the dial" {
						c.change(s, cyfr.port)
					}
				}
				a.makeAccount()
				if !read {
					t.Fatal("setup was never read")
				}
				noHello(t, cyfr, "the container that was not read")
				now, asked := cyfr.reached()
				if asked != requests || when == "before the dial" && now != conns {
					t.Fatalf("it got %d connections and %d requests", now-conns, asked-requests)
				}
				if page := a.page(); !strings.Contains(page, c.words) {
					t.Fatalf("the page does not say why:\n%s", page)
				}
			})
		}
	}
}

// The setup token goes on the connection bound to the container read and
// follows no redirect off it.
func TestTheTokensConnectionFollowsNoRedirect(t *testing.T) {
	s := newLocalStack(t)
	accounts := servingAccounts(t, "")
	var turned bool
	front := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/device/websocket" {
			turned = true
			http.Redirect(w, r, "https://elsewhere.example.com/device/websocket", http.StatusTemporaryRedirect)
			return
		}
		accounts.srv.Config.Handler.ServeHTTP(w, r)
	}))
	t.Cleanup(front.Close)
	home := "http://localhost:" + strconv.Itoa(accounts.port)
	s.env(accounts.port)
	s.runs("c0ffee", s.project, nil, accounts.port)
	saved := dialTCP
	t.Cleanup(func() { dialTCP = saved })
	var strayed []string
	dialTCP = func(ctx context.Context, network, address string) (net.Conn, error) {
		if address != "127.0.0.1:"+strconv.Itoa(accounts.port) {
			strayed = append(strayed, address)
			return nil, errors.New("the test makes no such connection")
		}
		return saved(ctx, network, front.Listener.Addr().String())
	}
	savedProxy := computersProxy
	t.Cleanup(func() { computersProxy = savedProxy })
	computersProxy = func(*http.Request) (*url.URL, error) { return nil, nil }
	a := newLocalApp(t, s.project)
	a.open(home, home)
	a.makeAccount()
	if !turned || len(strayed) != 0 {
		t.Fatalf("redirected %v, it connected to %v", turned, strayed)
	}
}

// With public and with tailnet access everything cyfr sends that CYFR, the
// setup token and the channel among it, goes to the loopback listener its
// folder's container publishes, under the configured address's name, and
// nothing to that name or through a proxy. The app's engine keeps its own
// route, a tailnet CYFR's through the folder's SOCKS5 proxy.
func TestEveryAccessModeIsReachedOnThisComputer(t *testing.T) {
	for _, c := range []struct {
		mode  string
		route []string
	}{
		{access.ModePublic, nil},
		{access.ModeTailnet, []string{"socks5://127.0.0.1:1055", "MAP * ~NOTFOUND, EXCLUDE 127.0.0.1"}},
	} {
		t.Run(c.mode, func(t *testing.T) {
			s := newLocalStack(t)
			accounts := accounttest.New(t)
			raw, err := url.Parse(accounts.URL())
			if err != nil {
				t.Fatal(err)
			}
			cyfr := newListening(t, httputil.NewSingleHostReverseProxy(raw))
			home := s.envReached(c.mode, cyfr.port)
			accounts.ServedAt(home)
			cyfr.admitting = home
			s.runs("c0ffee", s.project, nil, cyfr.port) // and no proxy's container
			here := "127.0.0.1:" + strconv.Itoa(cyfr.port)
			dialled, proxied := onlyOnThisComputer(t, here, nil)
			a := newLocalApp(t, s.project)
			a.open(home, home, c.route...)
			a.makeAccount()
			admission, _ := helloOf(t, cyfr)["admission"].(map[string]any)
			if admission["setup"] != testToken {
				t.Fatalf("the first hello's admission is %v", admission)
			}
			select {
			case connect := <-cyfr.connects:
				if connect["client_id"] != "pcl_1" {
					t.Fatalf("the channel connected as %v", connect)
				}
			default:
				t.Fatal("the channel never connected")
			}
			if to := dialled(); len(to) == 0 || slices.ContainsFunc(to, func(at string) bool { return at != here }) {
				t.Fatalf("connected to %v, want %s alone", to, here)
			}
			if asked := proxied(); len(asked) != 0 {
				t.Fatalf("this computer's proxy was asked for %v", asked)
			}
			cyfr.mu.Lock()
			defer cyfr.mu.Unlock()
			for _, asked := range cyfr.asked {
				if !strings.HasPrefix(asked, strings.TrimPrefix(home, "https://")+"/") {
					t.Errorf("%s was asked under another name than %s", asked, home)
				}
			}
		})
	}
}

// A box in tailnet access with nobody set up sets itself up at its own
// screen, with no proxy and no other device: its first hello brings the
// setup token to the loopback listener and that person is admitted.
func TestAFirstPersonIsAdmittedAtABoxInTailnetAccess(t *testing.T) {
	s := newLocalStack(t)
	accounts := accounttest.New(t)
	raw, err := url.Parse(accounts.URL())
	if err != nil {
		t.Fatal(err)
	}
	cyfr := newListening(t, httputil.NewSingleHostReverseProxy(raw))
	home := s.envReached(access.ModeTailnet, cyfr.port)
	accounts.ServedAt(home)
	cyfr.admitting = home
	s.runs("c0ffee", s.project, nil, cyfr.port)
	here := "127.0.0.1:" + strconv.Itoa(cyfr.port)
	onlyOnThisComputer(t, here, nil)

	local, err := readLocal(s.project, "screen")
	if err != nil {
		t.Fatal(err)
	}
	device := t.TempDir()
	clients := shell.ClientFile(filepath.Join(device, "client.json"))
	if err := clients.SelectProject(s.project); err != nil {
		t.Fatal(err)
	}
	cfg := local.Shell
	cfg.Record, cfg.Clients = filepath.Join(device, "holder.json"), clients
	cfg.Chip = func() bool { return false }
	cfg.Detect = func(string) disk.Report { return disk.Report{Root: disk.Unknown, Data: disk.Unknown} }
	screen, err := shell.New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { screen.Lock("") })
	makeAccountOn(t, &shell.Server{Shell: screen})
	admission, _ := helloOf(t, cyfr)["admission"].(map[string]any)
	kept, err := clients.Load()
	if err != nil || admission["setup"] != testToken || kept.ClientID != "pcl_1" {
		t.Fatalf("the first person was not admitted: client %q, admission %v (%v)", kept.ClientID, admission, err)
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
}

// The folder's own address takes no proxy of the environment in any
// access mode, nor the tailnet's, and needs no proxy's container running.
// Anywhere else takes this computer's own way, the environment's proxy
// and never the tailnet's.
func TestAFoldersOwnAddressTakesNoProxy(t *testing.T) {
	for _, mode := range []string{access.ModeLocal, access.ModePublic, access.ModeTailnet} {
		t.Run(mode, func(t *testing.T) {
			s := newLocalStack(t)
			cyfr := newListening(t, http.NotFoundHandler())
			if mode == access.ModeLocal {
				s.env(cyfr.port)
			} else {
				s.envReached(mode, cyfr.port)
			}
			s.runs("c0ffee", s.project, nil, cyfr.port)
			here := "127.0.0.1:" + strconv.Itoa(cyfr.port)
			dialled, proxied := onlyOnThisComputer(t, here, &url.URL{Scheme: "http", Host: "proxy.example:3128"})
			l, err := readLocal(s.project, "the test")
			if err != nil {
				t.Fatal(err)
			}
			if err := l.Answers(t.Context()); err != nil {
				t.Fatalf("it does not answer: %v", err)
			}
			if to, asked := dialled(), proxied(); !slices.Equal(to, []string{here}) || len(asked) != 0 {
				t.Fatalf("it was reached at %v, a proxy asked for %v", to, asked)
			}
			if resp, err := l.Shell.Client.Get("https://accounts.example.com/"); err == nil {
				resp.Body.Close()
			}
			if to := dialled(); to[len(to)-1] != "proxy.example:3128" {
				t.Fatalf("elsewhere was reached by %v, not this computer's way", to)
			}
		})
	}
}

// Where no answer came, only that is said: not that the folder's CYFR
// runs, which a Docker that never answered did not say.
func TestNoAnswerSaysNoMoreThanThat(t *testing.T) {
	s := newLocalStack(t)
	silent, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { silent.Close() })
	port := silent.Addr().(*net.TCPAddr).Port
	s.env(port)
	s.runs("c0ffee", s.project, nil, port)
	local, err := readLocal(s.project, "screen")
	if err != nil {
		t.Fatal(err)
	}
	ended, end := context.WithCancel(t.Context())
	end()
	err = local.Answers(ended)
	want := "No answer came from the CYFR in " + s.project + ". Check with docker ps that Docker answers and CYFR runs, then try again in a moment."
	if err == nil || err.Error() != want {
		t.Fatalf("said %v", err)
	}
}

// A folder that cannot be opened is said so, and that Docker was not asked.
func TestAFolderThatCannotBeOpenedBlamesNoDocker(t *testing.T) {
	s := newLocalStack(t)
	s.env(4321)
	local, err := readLocal(s.project, "screen")
	if err != nil {
		t.Fatal(err)
	}
	saved := openEngine
	t.Cleanup(func() { openEngine = saved })
	openEngine = func(string) (stackEngine, error) { return nil, errors.New("its compose file is missing") }
	err = local.Answers(t.Context())
	want := "The CYFR in " + s.project + " could not be opened here (its compose file is missing), so Docker was not asked and nothing was sent to it. Correct that, then try again."
	if err == nil || err.Error() != want {
		t.Fatalf("said %v", err)
	}
}

// unlockedLocalApp is a localApp unlocked at its folder's CYFR, every
// restart of its pages passing through restarted once main was told.
func unlockedLocalApp(t *testing.T, restarted func()) (a *localApp, home string) {
	t.Helper()
	s := newLocalStack(t)
	cyfr := servingAccounts(t, "")
	home = "http://localhost:" + strconv.Itoa(cyfr.port)
	cyfr.admitting, cyfr.holds = home, true
	s.env(cyfr.port)
	s.runs("c0ffee", s.project, nil, cyfr.port)
	a = newLocalApp(t, s.project)
	adapt := a.Shell
	a.Shell = func(c *shell.Config) {
		adapt(c)
		say := c.Restart
		c.Restart = func() {
			say()
			restarted()
		}
	}
	a.open(home, home)
	if m := a.heard(); m.Type != desktop.TypeOpened {
		t.Fatalf("main heard %+v", m)
	}
	a.makeAccount()
	return a, home
}

// heard is the next message cyfr said to main.
func (a *localApp) heard() desktop.Message {
	a.t.Helper()
	select {
	case m := <-a.sent:
		return m
	case <-time.After(20 * time.Second):
		a.t.Fatal("cyfr said nothing to main")
	}
	return desktop.Message{}
}

// A lock that closed a channel is said once, by the shell as it restarts
// the pages.
func TestALockOfAnUnlockedAppIsSaidOnce(t *testing.T) {
	var restarts int
	a, home := unlockedLocalApp(t, func() { restarts++ })
	a.Lock("Locked.")
	if restarts != 1 {
		t.Fatalf("the pages restarted %d times: the app was not unlocked", restarts)
	}
	if m := a.heard(); m.Type != desktop.TypeLocked || m.Home != home {
		t.Fatalf("main heard %+v", m)
	}
	select {
	case m := <-a.sent:
		t.Fatalf("main heard the one lock again: %+v", m)
	default:
	}
}

// Main's leave that arrives while the shell's own lock still restarts the
// pages is answered a locked naming none all the same: the lock before it
// named the CYFR main then left, and main keeps to that until told.
func TestALeaveDuringTheShellsOwnLockLeavesMainOnNone(t *testing.T) {
	restarting, release := make(chan struct{}), make(chan struct{})
	var once sync.Once
	a, home := unlockedLocalApp(t, func() {
		once.Do(func() {
			close(restarting)
			<-release
		})
	})
	letGo := sync.OnceFunc(func() { close(release) })
	t.Cleanup(letGo)
	pressedLock := make(chan struct{})
	go func() {
		r := httptest.NewRequest(http.MethodGet, shell.Origin+"/lock", nil)
		r.Host = shell.Listen
		a.ServeHTTP(httptest.NewRecorder(), r)
		close(pressedLock)
	}()
	select {
	case <-restarting:
	case <-time.After(20 * time.Second):
		t.Fatal("the shell's own lock restarted nothing")
	}
	if m := a.heard(); m.Type != desktop.TypeLocked || m.Home != home {
		t.Fatalf("main heard %+v", m)
	}
	left := make(chan error, 1)
	go func() { left <- a.Run(strings.NewReader(`{"version":1,"type":"leave"}` + "\n")) }()
	// Held until leave waits for the shell that lock holds: what it reads
	// before that wait, it read inside the other's restart.
	stacks := make([]byte, 1<<20)
	// Each by its whole name, as a line of a stack begins and its
	// arguments end it: a name these begin is another function.
	const (
		leaving = "\ngithub.com/cyfr/codex/internal/desktop.(*Service).Run("
		waiting = "\ngithub.com/cyfr/codex/internal/shell.(*shellLock).Lock("
	)
	waits := func(one string) bool {
		return strings.Contains(one, leaving) && strings.Contains(one, waiting)
	}
	for deadline := time.Now().Add(20 * time.Second); !slices.ContainsFunc(
		strings.Split(string(stacks[:runtime.Stack(stacks, true)]), "\n\n"), waits); {
		if time.Now().After(deadline) {
			t.Fatal("leave never waited for the lock restarting the pages")
		}
		time.Sleep(5 * time.Millisecond) // sleep-ok: polls for leave's wait, which says nothing as it begins
	}
	letGo()
	<-pressedLock
	if err := <-left; err != nil {
		t.Fatal(err)
	}
	if m := a.heard(); m.Type != desktop.TypeLocked || m.Home != "" {
		t.Fatalf("main heard %+v, not a lock naming none", m)
	}
}
