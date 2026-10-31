// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"maps"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/cyfr/codex/internal/config"
	"github.com/cyfr/codex/internal/mcp"
	"github.com/cyfr/codex/internal/prompt"
)

// devicePollServer answers every session.device_poll with the given status.
func devicePollServer(status string) *httptest.Server {
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		resp := map[string]any{
			"jsonrpc": "2.0",
			"id":      1,
			"result": map[string]any{
				"content": []map[string]any{
					{"type": "text", "text": fmt.Sprintf(`{"status":%q}`, status)},
				},
			},
		}
		json.NewEncoder(w).Encode(resp)
	}))
}

// Cancellation must end device polling promptly.
func TestPollDeviceAuth_ReturnsPromptlyOnCancel(t *testing.T) {
	srv := devicePollServer("pending")
	defer srv.Close()

	client := mcp.NewClient(srv.URL)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	start := time.Now()
	done := make(chan error, 1)
	go func() {
		_, err := pollDeviceAuth(ctx, client, "github", "dev-code",
			50*time.Millisecond, time.Now().Add(30*time.Second), 30, "laptop")
		done <- err
	}()

	// Let at least one poll round-trip happen, then cancel mid-loop.
	time.Sleep(120 * time.Millisecond)
	cancel()

	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("want context.Canceled, got %v", err)
		}
		if elapsed := time.Since(start); elapsed > 2*time.Second {
			t.Fatalf("poll loop took %v to notice cancellation", elapsed)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("poll loop did not return after cancellation — it would spin until the deadline")
	}
}

func TestPollDeviceAuth_CompleteReturnsResult(t *testing.T) {
	srv := devicePollServer("complete")
	defer srv.Close()

	client := mcp.NewClient(srv.URL)
	result, err := pollDeviceAuth(t.Context(), client, "github", "dev-code",
		10*time.Millisecond, time.Now().Add(5*time.Second), 5, "laptop")
	if err != nil {
		t.Fatalf("pollDeviceAuth failed: %v", err)
	}
	if status, _ := result["status"].(string); status != "complete" {
		t.Errorf("want the complete poll result back, got %v", result)
	}
}

func TestPollDeviceAuth_DeniedStops(t *testing.T) {
	srv := devicePollServer("denied")
	defer srv.Close()

	client := mcp.NewClient(srv.URL)
	_, err := pollDeviceAuth(t.Context(), client, "github", "dev-code",
		10*time.Millisecond, time.Now().Add(5*time.Second), 5, "laptop")
	if err == nil || !strings.Contains(err.Error(), "Authorization denied") {
		t.Fatalf("want denial error, got %v", err)
	}
}

func TestPollDeviceAuth_DeadlineTimesOut(t *testing.T) {
	// Deadline already passed: the loop must not poll at all.
	client := mcp.NewClient("http://127.0.0.1:0")
	_, err := pollDeviceAuth(t.Context(), client, "github", "dev-code",
		10*time.Millisecond, time.Now().Add(-time.Second), 900, "laptop")
	if err == nil || !strings.Contains(err.Error(), "Login timed out") {
		t.Fatalf("want timeout error, got %v", err)
	}
}

// testSetupToken is the setup token the tests' .env holds.
const testSetupToken = "0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0"

// The attempt, identifier and recovery code the fake CYFR answers its first
// person with.
const (
	setupAttempt    = "att_first"
	setupIdentifier = "per_5e0b6c1d9a2f4e7b8c3d0a1f2e5b6c9d8a7f4e3b2c1d0e9f8a7b6c5d4e3f2a1b"
	setupCode       = "CYFR-7Q2M-XK4D-91PA-6TRZ"
)

// The sentences of the refusals registry.register answers the command line
// acts on.
var (
	nameTaken      = registerRefusals["name_taken"]
	nameReserved   = registerRefusals["name_reserved"]
	directorySlow  = registerRefusals["directory_unavailable"]
	registrySilent = registerRefusals["registry_unavailable"]
)

// The texts cyfr login --setup prints around the code.
const (
	codeSentence   = "If this CYFR is ever lost, this is the one thing that brings you back. Save it in your password manager. Press Enter once you saved it."
	signedInAsMira = "Signed in as @mira. Add another recovery code in Settings.\n"
	silentCyfrRun  = "cyfr.run did not answer. Run cyfr login --setup again to finish."
)

// setupHome is a CYFR's MCP endpoint as cyfr login --setup reaches it. The
// first session.setup makes the person and their attempt with the name it
// carries; each later one readmits them, answering the attempt with its code
// until person.recovery_code_saved and with none after. registry.register
// takes a name it carries in place of the attempt's, and refuses a name
// cyfr.run holds (held) with its sentence. refusals scripts the sentences
// calls are refused with, in turn, by tool and action ("session.setup").
type setupHome struct {
	*httptest.Server
	mu       sync.Mutex
	calls    []setupCall
	requests int
	refusals map[string][]string
	held     map[string]string
	setups   int
	name     string
	saved    bool
	// onCall, when set, runs as each call arrives, before its answer.
	onCall func(call string)
}

type setupCall struct {
	call          string
	arguments     map[string]any
	authorization string
}

func newSetupHome(t *testing.T) *setupHome {
	t.Helper()
	h := &setupHome{refusals: map[string][]string{}, held: map[string]string{}}
	version := protocolVersionFromVectors(t)
	h.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Method string         `json:"method"`
			Params map[string]any `json:"params"`
		}
		raw, _ := io.ReadAll(r.Body)
		if err := json.Unmarshal(raw, &req); err != nil {
			t.Errorf("unreadable request: %v", err)
		}
		w.Header().Set("Content-Type", "application/json")
		h.mu.Lock()
		h.requests++
		h.mu.Unlock()
		if req.Method == "server/discover" {
			json.NewEncoder(w).Encode(map[string]any{"jsonrpc": "2.0", "id": 1,
				"result": map[string]any{"supportedVersions": []string{version}}})
			return
		}

		tool, _ := req.Params["name"].(string)
		args, _ := req.Params["arguments"].(map[string]any)
		action, _ := args["action"].(string)
		call := tool + "." + action
		if h.onCall != nil {
			h.onCall(call)
		}
		h.mu.Lock()
		h.calls = append(h.calls, setupCall{call: call, arguments: args, authorization: r.Header.Get("Authorization")})
		answer, refusal := h.answer(call, args)
		h.mu.Unlock()

		if refusal != "" {
			json.NewEncoder(w).Encode(map[string]any{"jsonrpc": "2.0", "id": 1,
				"result": map[string]any{"content": []map[string]any{{"type": "text", "text": refusal}}, "isError": true}})
			return
		}
		text, _ := json.Marshal(answer)
		json.NewEncoder(w).Encode(map[string]any{"jsonrpc": "2.0", "id": 1,
			"result": map[string]any{"content": []map[string]any{{"type": "text", "text": string(text)}}}})
	}))
	t.Cleanup(h.Close)
	return h
}

// answer is the call's answer, or the sentence it is refused with.
func (h *setupHome) answer(call string, args map[string]any) (map[string]any, string) {
	if call == "registry.register" {
		// A name the call carries replaces the attempt's before cyfr.run
		// is asked, so a refused one stays the attempt's.
		if name, ok := args["name"].(string); ok {
			h.name = name
		}
	}
	if queue := h.refusals[call]; len(queue) > 0 {
		h.refusals[call] = queue[1:]
		return nil, queue[0]
	}

	switch call {
	case "session.setup":
		h.setups++
		if h.setups == 1 {
			h.name, _ = args["name"].(string)
		}
		recovery := map[string]any{"attempt_id": setupAttempt, "identifier": setupIdentifier, "name": h.name}
		if !h.saved {
			recovery["code"] = setupCode
		}
		return map[string]any{"session_token": fmt.Sprintf("setup-session-%d", h.setups), "user_id": "usr_first",
			"readmitted": h.setups > 1, "recovery": recovery}, ""
	case "registry.register":
		if refusal := h.held[h.name]; refusal != "" {
			return nil, refusal
		}
		return map[string]any{"attempt_id": setupAttempt, "identifier": setupIdentifier, "name": h.name}, ""
	case "person.recovery_code_saved":
		h.saved = true
		return map[string]any{"attempt_id": setupAttempt}, ""
	case "session.logout":
		return map[string]any{"message": "Logged out successfully"}, ""
	}
	return map[string]any{}, ""
}

func (h *setupHome) reached() int {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.requests
}

// sent is every call that reached the home, in order.
func (h *setupHome) sent() []setupCall {
	h.mu.Lock()
	defer h.mu.Unlock()
	return slices.Clone(h.calls)
}

// called is the calls' names, in order.
func (h *setupHome) called() []string {
	names := []string{}
	for _, c := range h.sent() {
		names = append(names, c.call)
	}
	return names
}

// each is every call of the name, in order.
func (h *setupHome) each(call string) []setupCall {
	var calls []setupCall
	for _, c := range h.sent() {
		if c.call == call {
			calls = append(calls, c)
		}
	}
	return calls
}

// inSetupProject makes the working directory a project of the test's own
// whose .env holds env, and a config whose current context is the home at
// url's.
func inSetupProject(t *testing.T, url, env string) string {
	t.Helper()
	t.Chdir(t.TempDir())
	if env != "" {
		if err := os.WriteFile(".env", []byte(env), 0600); err != nil {
			t.Fatal(err)
		}
	}
	return withContexts(t, "local", map[string]*config.Context{"local": {URL: url}})
}

// runLoginSetup runs cyfr login --setup with args under ctx, as a process of its
// own: --name keeps no value from an earlier run.
func runLoginSetup(t *testing.T, ctx context.Context, args ...string) (string, error) {
	t.Helper()
	flagLoginName = ""
	t.Cleanup(func() { flagLoginName = "" })
	return runLogin(t, ctx, append([]string{"login", "--setup"}, args...)...)
}

// savedToken is the session the context local holds.
func savedToken(t *testing.T, path string) string {
	t.Helper()
	return loadContexts(t, path).Contexts["local"].Token
}

// secretsKept checks that no recovery secret a setup sent, and the code
// unless shown is true, is in what the command printed or answered.
func secretsKept(t *testing.T, home *setupHome, out string, err error, shown bool) {
	t.Helper()
	said := out
	if err != nil {
		said += err.Error()
		if strings.Contains(err.Error(), setupCode) {
			t.Errorf("the error names the recovery code: %v", err)
		}
	}
	for _, setup := range home.each("session.setup") {
		if secret, _ := setup.arguments["recovery_secret"].(string); secret == "" || strings.Contains(said, secret) {
			t.Errorf("the recovery secret %q was printed or never sent:\n%s", secret, said)
		}
	}
	if !shown && strings.Contains(out, setupCode) {
		t.Errorf("the recovery code was printed:\n%s", out)
	}
}

// endedSession checks that the home was asked to end the session n with
// its own credential, last.
func endedSession(t *testing.T, home *setupHome, n int) {
	t.Helper()
	calls := home.sent()
	if len(calls) == 0 {
		t.Fatal("nothing reached the home")
	}
	last := calls[len(calls)-1]
	if want := fmt.Sprintf("Bearer setup-session-%d", n); last.call != "session.logout" || last.authorization != want {
		t.Errorf("the last call was %s with %q, want session.logout with %q", last.call, last.authorization, want)
	}
}

// cyfr login --setup --name sends the setup token .env holds, the machine's
// name, the name, a recovery secret and a request id it drew, with no
// credential; takes the name at cyfr.run and prints the code with the
// session; and once Enter is pressed says the code is saved, then keeps
// the session under the context and says who signed in.
func TestLoginSetup_MakesTheFirstPersonAndSignsThemIn(t *testing.T) {
	home := newSetupHome(t)
	path := inSetupProject(t, home.URL, "CYFR_ACCESS=local\nCYFR_SETUP_TOKEN= "+testSetupToken+" \n")
	term := onTerminal(t, false)
	term.enter()
	home.onCall = func(call string) {
		if call == "person.recovery_code_saved" && savedToken(t, path) != "" {
			t.Error("the session was kept before the code was saved")
		}
	}

	out, err := runLoginSetup(t, t.Context(), "--name", "mira")
	if err != nil {
		t.Fatalf("login --setup: %v\n%s", err, out)
	}
	want := "Your name is @mira.\nYour recovery code:\n" + setupCode + "\n" + codeSentence + "\n" + signedInAsMira
	if out != want {
		t.Errorf("login --setup printed\n%s\nwant\n%s", out, want)
	}
	if got := savedToken(t, path); got != "setup-session-1" {
		t.Errorf("the context holds %q, want the setup's session", got)
	}
	if got, want := home.called(), []string{"session.setup", "registry.register", "person.recovery_code_saved"}; !slices.Equal(got, want) {
		t.Fatalf("CYFR was asked %v, want %v", got, want)
	}

	setup := home.each("session.setup")[0]
	args := setup.arguments
	if got := slices.Sorted(maps.Keys(args)); !slices.Equal(got, []string{"action", "machine", "name", "recovery_secret", "request_id", "setup_token"}) {
		t.Errorf("the setup sent %v", got)
	}
	if args["setup_token"] != testSetupToken || args["machine"] != machineName() || args["name"] != "mira" {
		t.Errorf("the setup sent the token %v, machine %v and name %v", args["setup_token"], args["machine"], args["name"])
	}
	secret, _ := args["recovery_secret"].(string)
	if raw, err := base64.RawURLEncoding.Strict().DecodeString(secret); err != nil || len(raw) != 32 {
		t.Errorf("the recovery secret %q is not 32 bytes of unpadded base64url", secret)
	}
	if id, _ := args["request_id"].(string); !regexp.MustCompile(`\Areq_[0-9a-f]{32}\z`).MatchString(id) {
		t.Errorf("the request id %q is not req_ and 32 hexadecimal digits", id)
	}
	if setup.authorization != "" {
		t.Errorf("the setup carried the credential %q", setup.authorization)
	}

	register := home.each("registry.register")[0]
	if !maps.Equal(register.arguments, map[string]any{"action": "register"}) || register.authorization != "Bearer setup-session-1" {
		t.Errorf("the registration sent %v with %q", register.arguments, register.authorization)
	}
	saved := home.each("person.recovery_code_saved")[0]
	if !maps.Equal(saved.arguments, map[string]any{"action": "recovery_code_saved", "attempt_id": setupAttempt}) ||
		saved.authorization != "Bearer setup-session-1" {
		t.Errorf("the code was said saved with %v and %q", saved.arguments, saved.authorization)
	}
	secretsKept(t, home, out, err, true)
}

// On a terminal with no --name, the name is asked for, again while
// nothing is typed, and the @ written before it is not part of it.
func TestLoginSetup_AsksTheNameOnATerminal(t *testing.T) {
	home := newSetupHome(t)
	path := inSetupProject(t, home.URL, "CYFR_SETUP_TOKEN="+testSetupToken+"\n")
	term := onTerminal(t, true)
	term.lines <- "  "
	term.lines <- " @mira "
	term.enter()

	out, err := runLoginSetup(t, t.Context())
	if err != nil {
		t.Fatalf("login --setup: %v\n%s", err, out)
	}
	if !strings.HasPrefix(out, "Your name: @Your name: @Your name is @mira.\n") || !strings.HasSuffix(out, signedInAsMira) {
		t.Errorf("login --setup printed\n%s", out)
	}
	if name := home.each("session.setup")[0].arguments["name"]; name != "mira" {
		t.Errorf("the setup sent the name %q", name)
	}
	if got := savedToken(t, path); got != "setup-session-1" {
		t.Errorf("the context holds %q", got)
	}
}

// With no --name and no terminal to ask on, cyfr login --setup refuses
// without asking, though input waits; with a terminal whose input ends
// before a name, it refuses once asked. Either way nothing reaches CYFR
// and nothing is saved.
func TestLoginSetup_RefusesWithoutAName(t *testing.T) {
	for name, c := range map[string]struct {
		terminal bool
		args     []string
	}{
		"no terminal":               {false, nil},
		"no terminal, empty --name": {false, []string{"--name", " "}},
		"the input ends":            {true, nil},
	} {
		t.Run(name, func(t *testing.T) {
			home := newSetupHome(t)
			path := inSetupProject(t, home.URL, "CYFR_SETUP_TOKEN="+testSetupToken+"\n")
			term := onTerminal(t, c.terminal)
			if !c.terminal {
				term.lines <- "mira"
			}
			close(term.lines)
			out, err := runLoginSetup(t, t.Context(), c.args...)
			if err == nil || err.Error() != "Give your name with --name. It is yours for life." {
				t.Fatalf("login --setup answered %v\n%s", err, out)
			}
			if asked := strings.Contains(out, "Your name: @"); asked != c.terminal {
				t.Errorf("login --setup asked for the name: %t\n%s", asked, out)
			}
			if n := home.reached(); n != 0 {
				t.Errorf("%d requests reached CYFR", n)
			}
			if got := savedToken(t, path); got != "" {
				t.Errorf("the context holds %q", got)
			}
		})
	}
}

// A name cyfr.run holds for someone else, or keeps for itself, is asked
// for again on a terminal and taken in place of the attempt's.
func TestLoginSetup_ATakenNameIsAskedForAgain(t *testing.T) {
	for _, refusal := range []string{nameTaken, nameReserved} {
		t.Run(refusal, func(t *testing.T) {
			home := newSetupHome(t)
			home.held["mira"] = refusal
			path := inSetupProject(t, home.URL, "CYFR_SETUP_TOKEN="+testSetupToken+"\n")
			term := onTerminal(t, true)
			term.lines <- "mira-2"
			term.enter()

			out, err := runLoginSetup(t, t.Context(), "--name", "mira")
			if err != nil {
				t.Fatalf("login --setup: %v\n%s", err, out)
			}
			if !strings.HasPrefix(out, refusal+"\nYour name: @Your name is @mira-2.\n") ||
				!strings.HasSuffix(out, "Signed in as @mira-2. Add another recovery code in Settings.\n") {
				t.Errorf("login --setup printed\n%s", out)
			}
			registers := home.each("registry.register")
			if len(registers) != 2 || !maps.Equal(registers[0].arguments, map[string]any{"action": "register"}) ||
				!maps.Equal(registers[1].arguments, map[string]any{"action": "register", "name": "mira-2"}) {
				t.Errorf("the registrations sent %+v", registers)
			}
			if got := savedToken(t, path); got != "setup-session-1" {
				t.Errorf("the context holds %q", got)
			}
			secretsKept(t, home, out, err, true)
		})
	}
}

// Off a terminal a taken name ends the run with cyfr.run's sentence,
// keeping no session; run again with another --name, the readmission
// takes that name in place of the attempt's.
func TestLoginSetup_ATakenNameOffATerminalIsGivenAgain(t *testing.T) {
	home := newSetupHome(t)
	home.held["mira"] = nameTaken
	path := inSetupProject(t, home.URL, "CYFR_SETUP_TOKEN="+testSetupToken+"\n")
	onTerminal(t, false)

	out, err := runLoginSetup(t, t.Context(), "--name", "mira")
	if want := nameTaken + "\nRun cyfr login --setup --name NAME with another name to finish."; err == nil || err.Error() != want {
		t.Fatalf("login --setup answered %v, want %q\n%s", err, want, out)
	}
	if ExitStatus(err) != exitFailure {
		t.Errorf("the run exits %d", ExitStatus(err))
	}
	if got := savedToken(t, path); got != "" {
		t.Errorf("the context holds %q", got)
	}
	endedSession(t, home, 1)
	secretsKept(t, home, out, err, false)

	onTerminal(t, false).enter()
	out, err = runLoginSetup(t, t.Context(), "--name", "mira-2")
	if err != nil {
		t.Fatalf("login --setup again: %v\n%s", err, out)
	}
	if !strings.HasPrefix(out, "Your name is @mira-2.\nYour recovery code:\n"+setupCode+"\n") {
		t.Errorf("login --setup again printed\n%s", out)
	}
	registers := home.each("registry.register")
	if len(registers) != 3 || !maps.Equal(registers[1].arguments, map[string]any{"action": "register"}) ||
		!maps.Equal(registers[2].arguments, map[string]any{"action": "register", "name": "mira-2"}) {
		t.Errorf("the registrations sent %+v", registers)
	}
	if got := savedToken(t, path); got != "setup-session-2" {
		t.Errorf("the context holds %q", got)
	}
}

// A silent cyfr.run ends the run with exit 1, prints no code, saves nothing
// and ends the session; run again, the same attempt finishes.
func TestLoginSetup_ASilentCyfrRunSavesNothing(t *testing.T) {
	for _, refusal := range []string{directorySlow, registrySilent} {
		t.Run(refusal, func(t *testing.T) {
			home := newSetupHome(t)
			home.refusals["registry.register"] = []string{refusal}
			path := inSetupProject(t, home.URL, "CYFR_SETUP_TOKEN="+testSetupToken+"\n")
			onTerminal(t, false)

			out, err := runLoginSetup(t, t.Context(), "--name", "mira")
			if err == nil || err.Error() != silentCyfrRun {
				t.Fatalf("login --setup answered %v, want %q\n%s", err, silentCyfrRun, out)
			}
			if ExitStatus(err) != exitFailure {
				t.Errorf("the run exits %d", ExitStatus(err))
			}
			if got := savedToken(t, path); got != "" {
				t.Errorf("the context holds %q", got)
			}
			if got, want := home.called(), []string{"session.setup", "registry.register", "session.logout"}; !slices.Equal(got, want) {
				t.Errorf("CYFR was asked %v, want %v", got, want)
			}
			endedSession(t, home, 1)
			secretsKept(t, home, out, err, false)

			onTerminal(t, false).enter()
			out, err = runLoginSetup(t, t.Context(), "--name", "mira")
			if err != nil {
				t.Fatalf("login --setup again: %v\n%s", err, out)
			}
			if want := "Your name is @mira.\nYour recovery code:\n" + setupCode + "\n" + codeSentence + "\n" + signedInAsMira; out != want {
				t.Errorf("login --setup again printed\n%s", out)
			}
			setups := home.each("session.setup")
			if setups[0].arguments["recovery_secret"] == setups[1].arguments["recovery_secret"] ||
				setups[0].arguments["request_id"] == setups[1].arguments["request_id"] {
				t.Error("the second run sent the first run's secret or request id")
			}
			if got := savedToken(t, path); got != "setup-session-2" {
				t.Errorf("the context holds %q", got)
			}
		})
	}
}

// Readmitted once the code is saved, CYFR answers no code: the run takes
// the name, keeps the session and says who signed in, with no code and no
// wait.
func TestLoginSetup_TheReadmissionAfterTheCodeIsSaved(t *testing.T) {
	home := newSetupHome(t)
	path := inSetupProject(t, home.URL, "CYFR_SETUP_TOKEN="+testSetupToken+"\n")
	onTerminal(t, false).enter()
	if out, err := runLoginSetup(t, t.Context(), "--name", "mira"); err != nil {
		t.Fatalf("login --setup: %v\n%s", err, out)
	}

	onTerminal(t, false)
	out, err := runLoginSetup(t, t.Context(), "--name", "mira")
	if err != nil {
		t.Fatalf("login --setup again: %v\n%s", err, out)
	}
	if out != signedInAsMira {
		t.Errorf("login --setup again printed\n%s", out)
	}
	if got, want := home.called()[3:], []string{"session.setup", "registry.register"}; !slices.Equal(got, want) {
		t.Errorf("the readmission asked %v, want %v", got, want)
	}
	if got := savedToken(t, path); got != "setup-session-2" {
		t.Errorf("the context holds %q", got)
	}
}

// Input that ends, or the person leaving, before Enter keeps no session,
// says nothing saved and ends the session.
func TestLoginSetup_NoEnterSavesNothing(t *testing.T) {
	t.Run("the input ends", func(t *testing.T) {
		home := newSetupHome(t)
		path := inSetupProject(t, home.URL, "CYFR_SETUP_TOKEN="+testSetupToken+"\n")
		close(onTerminal(t, false).lines)

		out, err := runLoginSetup(t, t.Context(), "--name", "mira")
		if err == nil || !strings.HasPrefix(err.Error(), "The input ended before you saved your recovery code, so nothing was saved.") {
			t.Fatalf("login --setup answered %v\n%s", err, out)
		}
		if got := savedToken(t, path); got != "" {
			t.Errorf("the context holds %q", got)
		}
		if len(home.each("person.recovery_code_saved")) != 0 {
			t.Error("the code was said saved")
		}
		endedSession(t, home, 1)
		secretsKept(t, home, out, err, true)
	})

	t.Run("Ctrl-C", func(t *testing.T) {
		home := newSetupHome(t)
		path := inSetupProject(t, home.URL, "CYFR_SETUP_TOKEN="+testSetupToken+"\n")
		onTerminal(t, false)
		ctx, cancel := context.WithCancel(t.Context())
		defer cancel()
		// The person leaves as the command waits for Enter, its one read.
		confirmationInput = func() <-chan string {
			cancel()
			return make(chan string)
		}

		out, err := runLoginSetup(t, ctx, "--name", "mira")
		if !errors.Is(err, prompt.ErrAborted) || ExitStatus(err) != exitInterrupted {
			t.Fatalf("login --setup answered %v\n%s", err, out)
		}
		if !strings.Contains(out, "Stopped before you saved your recovery code.") {
			t.Errorf("login --setup printed\n%s", out)
		}
		if got := savedToken(t, path); got != "" {
			t.Errorf("the context holds %q", got)
		}
		if len(home.each("person.recovery_code_saved")) != 0 {
			t.Error("the code was said saved")
		}
		endedSession(t, home, 1)
	})
}

// Under --json the answer alone is on standard output, naming the person
// and never the code, which is printed with the rest on standard error.
func TestLoginSetup_JSONAnswersWithoutTheCode(t *testing.T) {
	home := newSetupHome(t)
	inSetupProject(t, home.URL, "CYFR_SETUP_TOKEN="+testSetupToken+"\n")
	onTerminal(t, false).enter()

	out, err := runLoginSetup(t, t.Context(), "--name", "mira", "--json")
	if err != nil {
		t.Fatalf("login --setup --json: %v\n%s", err, out)
	}
	// The capture is standard output, then standard error.
	decoder := json.NewDecoder(strings.NewReader(out))
	var answer map[string]any
	if err := decoder.Decode(&answer); err != nil {
		t.Fatalf("standard output does not start with the answer: %v\n%s", err, out)
	}
	want := map[string]any{"status": "signed_in", "context": "local", "user_id": "usr_first", "readmitted": false,
		"name": "mira", "identifier": setupIdentifier}
	if !maps.Equal(answer, want) {
		t.Errorf("the answer is %v, want %v", answer, want)
	}
	rest := out[decoder.InputOffset():]
	if !strings.Contains(rest, "Your recovery code:\n"+setupCode+"\n") {
		t.Errorf("standard error lacks the code:\n%s", rest)
	}
}

// Without a setup token in the working directory's .env, cyfr login
// --setup is refused naming .env before anything reaches CYFR, and saves
// nothing.
func TestLoginSetup_RefusesWithoutATokenInEnv(t *testing.T) {
	for name, c := range map[string]struct{ env, want string }{
		"no .env":             {"", "There is no .env here, so no CYFR_SETUP_TOKEN: run cyfr login --setup in the directory cyfr init set up."},
		".env without it":     {"CYFR_ACCESS=local\n", "There is no CYFR_SETUP_TOKEN in .env here: run cyfr login --setup in the directory cyfr init set up."},
		".env assigning none": {"CYFR_ACCESS=local\nCYFR_SETUP_TOKEN=\n", "There is no CYFR_SETUP_TOKEN in .env here: run cyfr login --setup in the directory cyfr init set up."},
	} {
		t.Run(name, func(t *testing.T) {
			home := newSetupHome(t)
			path := inSetupProject(t, home.URL, c.env)
			onTerminal(t, false)
			out, err := runLoginSetup(t, t.Context(), "--name", "mira")
			if err == nil || err.Error() != c.want {
				t.Fatalf("login --setup answered %v, want %q\n%s", err, c.want, out)
			}
			if n := home.reached(); n != 0 {
				t.Errorf("%d requests reached CYFR", n)
			}
			if got := savedToken(t, path); got != "" {
				t.Errorf("the context holds %q", got)
			}
		})
	}
}

// --setup and --provider together, and --name without --setup, are
// refused before anything reaches CYFR.
func TestLoginSetup_RefusesFlagsThatDoNotGoTogether(t *testing.T) {
	home := newSetupHome(t)
	inSetupProject(t, home.URL, "CYFR_SETUP_TOKEN="+testSetupToken+"\n")
	onTerminal(t, false)

	_, err := runLoginSetup(t, t.Context(), "--name", "mira", "--provider", "github")
	if err == nil || !strings.Contains(err.Error(), "--setup") || !strings.Contains(err.Error(), "--provider") {
		t.Errorf("login --setup --provider answered %v", err)
	}
	flagLoginName = ""
	_, err = runLogin(t, t.Context(), "login", "--name", "mira")
	if err == nil || err.Error() != "--name names the first person --setup makes: use it with --setup." {
		t.Errorf("login --name answered %v", err)
	}
	if n := home.reached(); n != 0 {
		t.Errorf("%d requests reached CYFR", n)
	}
}

// A CYFR whose first person has a sign-in method refuses the setup token:
// the command line says CYFR's sentence and that cyfr login signs it in,
// and saves nothing.
func TestLoginSetup_SetupClosedNamesCyfrLogin(t *testing.T) {
	const closed = "This CYFR is set up. Sign in with your passkey, a device you connected, or a sign-in method you linked."
	home := newSetupHome(t)
	home.refusals["session.setup"] = []string{closed}
	path := inSetupProject(t, home.URL, "CYFR_SETUP_TOKEN="+testSetupToken+"\n")
	onTerminal(t, false)
	_, err := runLoginSetup(t, t.Context(), "--name", "mira")
	if err == nil || !strings.HasPrefix(err.Error(), closed+"\n") || !strings.Contains(err.Error(), "signs in with cyfr login.") {
		t.Fatalf("login --setup answered %v, want CYFR's sentence and cyfr login", err)
	}
	if got := savedToken(t, path); got != "" {
		t.Errorf("the context holds %q", got)
	}
	if got := home.called(); !slices.Equal(got, []string{"session.setup"}) {
		t.Errorf("CYFR was asked %v", got)
	}
}

// A CYFR that does not answer is the command line's connection refusal,
// as cyfr login's.
func TestLoginSetup_ServerDownIsAConnectionRefusal(t *testing.T) {
	home := newSetupHome(t)
	inSetupProject(t, home.URL, "CYFR_SETUP_TOKEN="+testSetupToken+"\n")
	onTerminal(t, false)
	home.Close()
	_, err := runLoginSetup(t, t.Context(), "--name", "mira")
	if err == nil || !strings.HasPrefix(err.Error(), "Failed to connect: ") {
		t.Fatalf("login --setup answered %v, want the connection refusal", err)
	}
}

// A context changed to another address while the setup signs in keeps
// nothing: the session is ended at the CYFR that issued it.
func TestLoginSetup_EndsTheSessionWhenTheContextMoved(t *testing.T) {
	home := newSetupHome(t)
	path := inSetupProject(t, home.URL, "CYFR_SETUP_TOKEN="+testSetupToken+"\n")
	onTerminal(t, false).enter()
	home.onCall = func(call string) {
		if call == "session.setup" {
			cfg := loadContexts(t, path)
			cfg.Contexts["local"].URL = "https://other.example"
			if err := cfg.SaveTo(path); err != nil {
				t.Error(err)
			}
		}
	}
	_, err := runLoginSetup(t, t.Context(), "--name", "mira")
	if err == nil || !errors.Is(err, errContextMoved) || !strings.Contains(err.Error(), "the session was ended and nothing saved") {
		t.Fatalf("login --setup answered %v", err)
	}
	endedSession(t, home, 1)
	if got := loadContexts(t, path).Contexts["local"]; got.Token != "" || got.URL != "https://other.example" {
		t.Errorf("the moved context holds %+v", got)
	}
}

// The refusals the command line acts on are the sentences Prima.Refusal
// answers them with, word for word.
func TestLoginSetup_RegisterRefusalsAreCyfrsSentences(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "apps", "prima", "lib", "prima", "refusal.ex"))
	if err != nil {
		t.Fatalf("read refusal.ex: %v", err)
	}
	if len(registerRefusals) != 4 {
		t.Errorf("the command line acts on %d refusals, want 4", len(registerRefusals))
	}
	for reason, sentence := range registerRefusals {
		row := regexp.MustCompile(`defp row\(:` + reason + `\),\s*do:\s*\{:\w+,\s*"([^"]*)"\}`).FindSubmatch(raw)
		if row == nil {
			t.Errorf("refusal.ex has no single-sentence row for :%s", reason)
			continue
		}
		if string(row[1]) != sentence {
			t.Errorf(":%s is %q in refusal.ex, %q here", reason, row[1], sentence)
		}
	}
}
