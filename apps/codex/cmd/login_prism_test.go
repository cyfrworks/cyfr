// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/cyfr/codex/internal/config"
	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
)

// The token, link and code a stub home answers cli_begin with.
const (
	stubToken = "c3R1YiBzZXNzaW9uIHRva2VuIG9mIHRoaXJ0eS10d28gYg"
	stubCode  = "K7QM-3XRD"
	stubLink  = "https://home.example/cli#code=q2mTb0yU7aKpXv1ZcR4n8w"
)

// stubHome is a home's MCP endpoint as cyfr login reaches it: discovery,
// then the session tool's actions, each recorded with the credential it
// carried. Polls answer the statuses in order, the last one repeating.
type stubHome struct {
	*httptest.Server
	mu        sync.Mutex
	calls     []stubCall
	polls     []string
	expiresIn float64
	// failing names the actions the home answers 502 to.
	failing map[string]bool
	// onAction, when set, runs as each action arrives, before its answer.
	onAction func(action string)
}

type stubCall struct {
	action        string
	arguments     map[string]any
	authorization string
}

func newStubHome(t *testing.T, polls ...string) *stubHome {
	t.Helper()
	h := &stubHome{polls: polls, expiresIn: 30, failing: map[string]bool{}}
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
		if req.Method == "server/discover" {
			json.NewEncoder(w).Encode(map[string]any{"jsonrpc": "2.0", "id": 1,
				"result": map[string]any{"supportedVersions": []string{version}}})
			return
		}

		args, _ := req.Params["arguments"].(map[string]any)
		action, _ := args["action"].(string)
		if h.onAction != nil {
			h.onAction(action)
		}
		h.mu.Lock()
		h.calls = append(h.calls, stubCall{action: action, arguments: args,
			authorization: r.Header.Get("Authorization")})
		answer := h.answer(action)
		fail := h.failing[action]
		h.mu.Unlock()

		if fail {
			w.WriteHeader(http.StatusBadGateway)
			return
		}
		text, _ := json.Marshal(answer)
		json.NewEncoder(w).Encode(map[string]any{"jsonrpc": "2.0", "id": 1,
			"result": map[string]any{"content": []map[string]any{{"type": "text", "text": string(text)}}}})
	}))
	t.Cleanup(h.Close)
	return h
}

func (h *stubHome) answer(action string) map[string]any {
	switch action {
	case "cli_begin":
		return map[string]any{"session_token": stubToken, "user_code": stubCode,
			"approve_url": stubLink, "expires_in": h.expiresIn, "interval": 0.01}
	case "cli_poll":
		status := "pending"
		if len(h.polls) > 0 {
			status = h.polls[0]
			if len(h.polls) > 1 {
				h.polls = h.polls[1:]
			}
		}
		return map[string]any{"status": status, "interval": 0.01}
	case "cli_cancel":
		return map[string]any{"status": "cancelled"}
	case "whoami":
		return map[string]any{"email": "alice@example.com"}
	case "device_init":
		return map[string]any{"device_code": "dc", "user_code": "WDJB-MJHT",
			"verification_uri": "https://github.com/login/device", "expires_in": 30, "interval": 0}
	case "device_poll":
		return map[string]any{"status": "complete", "session_token": "provider-session",
			"user": map[string]any{"email": "alice@example.com"}}
	case "logout":
		return map[string]any{"message": "Logged out successfully"}
	}
	return map[string]any{}
}

func (h *stubHome) actions() []string {
	h.mu.Lock()
	defer h.mu.Unlock()
	actions := make([]string, len(h.calls))
	for i, c := range h.calls {
		actions[i] = c.action
	}
	return actions
}

func (h *stubHome) call(action string) (stubCall, bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for _, c := range h.calls {
		if c.action == action {
			return c, true
		}
	}
	return stubCall{}, false
}

// protocolVersionFromVectors reads the MCP revision both sides speak from
// the shared wire vectors.
func protocolVersionFromVectors(t *testing.T) string {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "tests", "fixtures", "mcp_wire.json"))
	if err != nil {
		t.Fatalf("the wire vectors: %v", err)
	}
	var vectors struct {
		ProtocolVersion string `json:"protocol_version"`
	}
	if err := json.Unmarshal(raw, &vectors); err != nil || vectors.ProtocolVersion == "" {
		t.Fatalf("the wire vectors name no protocol version: %v", err)
	}
	return vectors.ProtocolVersion
}

// withContexts writes a config of the given contexts, current first, under
// a home of the test's own, and answers its path.
func withContexts(t *testing.T, current string, contexts map[string]*config.Context) string {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("CYFR_TOKEN", "")
	cfg := &config.Config{CurrentContext: current, Contexts: contexts}
	path := filepath.Join(home, ".cyfr", "config.json")
	if err := cfg.SaveTo(path); err != nil {
		t.Fatalf("writing the config: %v", err)
	}
	return path
}

func loadContexts(t *testing.T, path string) *config.Config {
	t.Helper()
	cfg, err := config.LoadFrom(path)
	if err != nil {
		t.Fatalf("reading the config: %v", err)
	}
	return cfg
}

// runLogin runs the command line with args, as given, under ctx.
func runLogin(t *testing.T, ctx context.Context, args ...string) (string, error) {
	t.Helper()
	// Cobra keeps a flag's value from one execution to the next; each run
	// here is a process of its own.
	reset := func() {
		flagJSON, flagURL, flagContext, flagNoInteractive, flagToken = false, "", "", false, ""
		flagLoginProvider = ""
		rootCmd.SetArgs(nil)
	}
	reset()
	t.Cleanup(reset)
	var forget func(c *cobra.Command)
	forget = func(c *cobra.Command) {
		c.SetContext(nil)
		for _, sub := range c.Commands() {
			sub.Flags().VisitAll(func(f *pflag.Flag) { f.Changed = false })
			forget(sub)
		}
	}
	forget(rootCmd)
	rootCmd.SetArgs(args)
	var err error
	out := captureStdout(t, func() { err = Execute(ctx) })
	return out, err
}

// cyfr login with no flag prints the link and the code, waits, and once
// approved saves the token the home answered at its begin under the
// current context and says who signed in. The begin, the polls and the
// cancel carry no credential: a revoked one the context held would refuse
// them.
func TestLogin_ApprovedInPrismSavesTheSessionUnderItsContext(t *testing.T) {
	home := newStubHome(t, "pending", "approved")
	path := withContexts(t, "home", map[string]*config.Context{
		"home": {URL: home.URL, Token: "a-revoked-session"},
	})

	out, err := runLogin(t, t.Context(), "login")
	if err != nil {
		t.Fatalf("login: %v\n%s", err, out)
	}

	for _, want := range []string{stubLink, stubCode, "Approve the command line on", "Signed in as alice@example.com."} {
		if !strings.Contains(out, want) {
			t.Errorf("the output names no %q:\n%s", want, out)
		}
	}
	if got := loadContexts(t, path).Contexts["home"].Token; got != stubToken {
		t.Errorf("the context holds %q, want the token the home answered", got)
	}

	begin, _ := home.call("cli_begin")
	if machine, _ := begin.arguments["machine"].(string); machine == "" {
		t.Errorf("the begin named no machine: %v", begin.arguments)
	}
	for _, action := range []string{"cli_begin", "cli_poll"} {
		if c, _ := home.call(action); c.authorization != "" {
			t.Errorf("%s carried the credential %q", action, c.authorization)
		}
	}
	if c, _ := home.call("whoami"); c.authorization != "Bearer "+stubToken {
		t.Errorf("whoami carried %q, want the new session", c.authorization)
	}
	if _, cancelled := home.call("cli_cancel"); cancelled {
		t.Error("an approved sign-in was withdrawn")
	}
}

// Each ending the home answers is said, saves nothing and exits 1.
func TestLogin_TheHomesEndingsAreSaid(t *testing.T) {
	for status, want := range map[string]string{
		"expired":   "expired before it was approved",
		"cancelled": "withdrawn",
		"revoked":   "revoked in Prism",
	} {
		t.Run(status, func(t *testing.T) {
			home := newStubHome(t, "pending", status)
			path := withContexts(t, "home", map[string]*config.Context{"home": {URL: home.URL}})

			out, err := runLogin(t, t.Context(), "login")
			if !exitsOne(err) || !strings.Contains(err.Error(), want) {
				t.Fatalf("want an error saying %q, got %v\n%s", want, err, out)
			}
			if got := loadContexts(t, path).Contexts["home"].Token; got != "" {
				t.Errorf("the context holds %q after %s", got, status)
			}
		})
	}
}

// Ctrl-C withdraws the sign-in, so an approval landing later signs
// nothing in, and exits 130 as an interrupt.
func TestLogin_CtrlCWithdrawsTheSignIn(t *testing.T) {
	home := newStubHome(t, "pending")
	path := withContexts(t, "home", map[string]*config.Context{"home": {URL: home.URL}})

	ctx, cancel := context.WithCancel(t.Context())
	go func() {
		for {
			if n := len(home.actions()); n >= 2 {
				cancel()
				return
			}
			time.Sleep(5 * time.Millisecond)
		}
	}()

	out, err := runLogin(t, ctx, "login")
	if ExitStatus(err) != exitInterrupted {
		t.Fatalf("want the interrupt's 130, got %v (%d)\n%s", err, ExitStatus(err), out)
	}
	if !strings.Contains(out, "withdrawn") {
		t.Errorf("the output does not say the sign-in was withdrawn:\n%s", out)
	}
	cancelled, ok := home.call("cli_cancel")
	if !ok || cancelled.arguments["session_token"] != stubToken {
		t.Fatalf("no withdrawal of the token reached the home: %v", home.actions())
	}
	if got := loadContexts(t, path).Contexts["home"].Token; got != "" {
		t.Errorf("the context holds %q after an interrupt", got)
	}
}

// The link's expiry passing while the home says it waits withdraws the
// sign-in too, and says it expired.
func TestLogin_TheDeadlineWithdrawsTheSignIn(t *testing.T) {
	home := newStubHome(t, "pending")
	home.expiresIn = 0.1
	withContexts(t, "home", map[string]*config.Context{"home": {URL: home.URL}})

	out, err := runLogin(t, t.Context(), "login")
	if !exitsOne(err) || !strings.Contains(err.Error(), "expired before it was approved") {
		t.Fatalf("want the expiry, got %v\n%s", err, out)
	}
	if _, ok := home.call("cli_cancel"); !ok {
		t.Errorf("the expiry withdrew nothing: %v", home.actions())
	}
}

// A home that stops answering while the command line waits is said to be
// unreachable at the deadline, not merely expired; one that never answers
// fails at once.
func TestLogin_AnUnreachableHomeIsSaid(t *testing.T) {
	home := newStubHome(t)
	home.expiresIn = 0.2
	home.failing["cli_poll"] = true
	withContexts(t, "home", map[string]*config.Context{"home": {URL: home.URL}})

	out, err := runLogin(t, t.Context(), "login")
	if !exitsOne(err) || !strings.Contains(err.Error(), "Could not reach CYFR") {
		t.Fatalf("want the unreachable home said, got %v\n%s", err, out)
	}

	gone := httptest.NewServer(http.NotFoundHandler())
	gone.Close()
	withContexts(t, "home", map[string]*config.Context{"home": {URL: gone.URL}})
	out, err = runLogin(t, t.Context(), "login")
	if !exitsOne(err) || !strings.Contains(err.Error(), "Failed to connect") {
		t.Fatalf("want the connection failure, got %v\n%s", err, out)
	}
}

// --context names the context the session is saved under; before, the
// session went to the current context whatever --context named.
func TestLogin_SavesUnderTheContextItUsed(t *testing.T) {
	home := newStubHome(t, "approved")
	path := withContexts(t, "local", map[string]*config.Context{
		"local": {URL: "http://127.0.0.1:4000", Token: "local-session"},
		"home":  {URL: home.URL},
	})

	if out, err := runLogin(t, t.Context(), "login", "--context", "home"); err != nil {
		t.Fatalf("login: %v\n%s", err, out)
	}
	cfg := loadContexts(t, path)
	if cfg.Contexts["home"].Token != stubToken || cfg.Contexts["local"].Token != "local-session" {
		t.Errorf("the session was saved under the wrong context: home %q, local %q",
			cfg.Contexts["home"].Token, cfg.Contexts["local"].Token)
	}
}

// A --url that is not the context's address is refused before any home
// is asked: that home's session would be saved under another's context
// and sent there with every later command. So is a context that does not
// exist.
func TestLogin_RefusesAnAddressItWouldSaveUnderAnotherContext(t *testing.T) {
	home := newStubHome(t, "approved")
	withContexts(t, "local", map[string]*config.Context{"local": {URL: "http://127.0.0.1:4000"}})

	out, err := runLogin(t, t.Context(), "login", "--url", home.URL)
	if !exitsOne(err) || !strings.Contains(err.Error(), "cyfr context add") {
		t.Fatalf("want the refusal naming cyfr context add, got %v\n%s", err, out)
	}
	_, err = runLogin(t, t.Context(), "login", "--context", "nowhere")
	if !exitsOne(err) || !strings.Contains(err.Error(), `No context named "nowhere"`) {
		t.Fatalf("want the missing context refused, got %v", err)
	}
	if n := len(home.actions()); n != 0 {
		t.Errorf("a refused login asked the home %d things", n)
	}

	// The context's own address, a trailing slash aside, is no other.
	withContexts(t, "home", map[string]*config.Context{"home": {URL: home.URL}})
	if out, err := runLogin(t, t.Context(), "login", "--url", home.URL+"/"); err != nil {
		t.Fatalf("login at the context's own address: %v\n%s", err, out)
	}
}

// --provider keeps the GitHub or Google device flow, names the machine, so
// Prism lists the session as this command line's, and saves under the
// context it used.
func TestLogin_ProviderSignsInWithTheDeviceFlow(t *testing.T) {
	home := newStubHome(t)
	path := withContexts(t, "home", map[string]*config.Context{"home": {URL: home.URL}})

	out, err := runLogin(t, t.Context(), "login", "--provider", "github")
	if err != nil {
		t.Fatalf("login --provider: %v\n%s", err, out)
	}
	poll, ok := home.call("device_poll")
	if !ok {
		t.Fatalf("no device poll: %v", home.actions())
	}
	if machine, _ := poll.arguments["machine"].(string); machine == "" {
		t.Errorf("the device poll named no machine: %v", poll.arguments)
	}
	if _, began := home.call("cli_begin"); began {
		t.Error("--provider began a Prism approval too")
	}
	if got := loadContexts(t, path).Contexts["home"].Token; got != "provider-session" {
		t.Errorf("the context holds %q", got)
	}
}

// logout clears the session of the context it ended: --context's, not the
// current one's.
func TestLogout_ClearsTheContextItUsed(t *testing.T) {
	home := newStubHome(t)
	path := withContexts(t, "local", map[string]*config.Context{
		"local": {URL: "http://127.0.0.1:4000", Token: "local-session"},
		"home":  {URL: home.URL, Token: "home-session"},
	})

	if out, err := runLogin(t, t.Context(), "logout", "--context", "home"); err != nil {
		t.Fatalf("logout: %v\n%s", err, out)
	}
	cfg := loadContexts(t, path)
	if cfg.Contexts["home"].Token != "" || cfg.Contexts["local"].Token != "local-session" {
		t.Errorf("logout cleared the wrong context: home %q, local %q",
			cfg.Contexts["home"].Token, cfg.Contexts["local"].Token)
	}
	if c, _ := home.call("logout"); c.authorization != "Bearer home-session" {
		t.Errorf("logout ended %q", c.authorization)
	}
}

// The machine name the home is told is what it takes: 1 to 64 bytes of
// printable ASCII.
func TestMachineName_IsWhatTheHomeTakes(t *testing.T) {
	name := machineName()
	if len(name) == 0 || len(name) > 64 || strings.TrimSpace(name) != name {
		t.Fatalf("machine name %q", name)
	}
	for _, r := range name {
		if r < 0x20 || r > 0x7e {
			t.Fatalf("machine name %q holds %q", name, r)
		}
	}
}

// moveContext points the stored context name at address, as
// `cyfr context add <name> <address>` does while a command runs.
func moveContext(t *testing.T, path, name, address string) {
	t.Helper()
	cfg := loadContexts(t, path)
	cfg.Contexts[name] = &config.Context{URL: address}
	if err := cfg.SaveTo(path); err != nil {
		t.Errorf("moving the context: %v", err)
	}
}

// A context moved to another home while the approval waits keeps no
// session: the sign-in is withdrawn at the home that approved it, nothing
// is saved under the other address, and the next command sends that home
// no credential.
func TestLogin_WithdrawsWhenTheContextMovesWhileWaiting(t *testing.T) {
	home := newStubHome(t, "pending", "approved")
	other := newStubHome(t)
	path := withContexts(t, "home", map[string]*config.Context{"home": {URL: home.URL}})
	var once sync.Once
	home.onAction = func(action string) {
		if action == "cli_poll" {
			once.Do(func() { moveContext(t, path, "home", other.URL) })
		}
	}

	out, err := runLogin(t, t.Context(), "login")
	if !exitsOne(err) || !strings.Contains(err.Error(), "changed to another address") {
		t.Fatalf("want the moved context said, got %v\n%s", err, out)
	}
	stored := loadContexts(t, path).Contexts["home"]
	if stored.URL != other.URL || stored.Token != "" {
		t.Errorf("the moved context holds %q at %s", stored.Token, stored.URL)
	}
	if cancelled, ok := home.call("cli_cancel"); !ok || cancelled.arguments["session_token"] != stubToken {
		t.Errorf("the approving home's sign-in was not withdrawn: %v", home.actions())
	}

	if out, err := runLogin(t, t.Context(), "whoami"); err != nil {
		t.Logf("whoami: %v\n%s", err, out)
	}
	if c, ok := other.call("whoami"); !ok || c.authorization != "" {
		t.Errorf("the other home was sent %q (asked: %v)", c.authorization, ok)
	}
}

// --provider's session is ended at the home that issued it when the
// context moved meanwhile, and nothing is saved.
func TestLogin_ProviderEndsTheSessionWhenTheContextMoves(t *testing.T) {
	home := newStubHome(t)
	other := newStubHome(t)
	path := withContexts(t, "home", map[string]*config.Context{"home": {URL: home.URL}})
	home.onAction = func(action string) {
		if action == "device_poll" {
			moveContext(t, path, "home", other.URL)
		}
	}

	out, err := runLogin(t, t.Context(), "login", "--provider", "github")
	if !exitsOne(err) || !strings.Contains(err.Error(), "changed to another address") {
		t.Fatalf("want the moved context said, got %v\n%s", err, out)
	}
	if got := loadContexts(t, path).Contexts["home"].Token; got != "" {
		t.Errorf("the moved context holds %q", got)
	}
	if c, ok := home.call("logout"); !ok || c.authorization != "Bearer provider-session" {
		t.Errorf("the issuing home did not end the session: %q (%v)", c.authorization, ok)
	}
	if n := len(other.actions()); n != 0 {
		t.Errorf("the other home was asked %d things", n)
	}
}

// logout with a --url that is not the context's address is refused before
// anything is sent or cleared: that home would be handed this context's
// session.
func TestLogout_RefusesAnotherHomesAddress(t *testing.T) {
	home := newStubHome(t)
	other := newStubHome(t)
	path := withContexts(t, "home", map[string]*config.Context{
		"home": {URL: home.URL, Token: "home-session"},
	})

	out, err := runLogin(t, t.Context(), "logout", "--url", other.URL)
	if !exitsOne(err) || !strings.Contains(err.Error(), "is not the address of the context") {
		t.Fatalf("want the address refused, got %v\n%s", err, out)
	}
	if n := len(other.actions()) + len(home.actions()); n != 0 {
		t.Errorf("a refused logout asked a home %d things", n)
	}
	if got := loadContexts(t, path).Contexts["home"].Token; got != "home-session" {
		t.Errorf("a refused logout cleared the context's session: %q", got)
	}
}

// Two addresses are one home when they differ only in a trailing slash or
// in the case of their scheme and host; a path or a query in another case
// is another address.
func TestSameAddress_FoldsSchemeAndHostOnly(t *testing.T) {
	for _, pair := range [][2]string{
		{"https://home.example", "HTTPS://Home.Example/"},
		{"https://home.example/cyfr/", "https://home.example/cyfr"},
	} {
		if !sameAddress(pair[0], pair[1]) {
			t.Errorf("%s and %s are one home", pair[0], pair[1])
		}
	}
	for _, pair := range [][2]string{
		{"https://home.example/Home", "https://home.example/home"},
		{"https://home.example/?home=A", "https://home.example/?home=a"},
		{"https://home.example", "https://home.example:8443"},
		{"https://home.example", "http://home.example"},
	} {
		if sameAddress(pair[0], pair[1]) {
			t.Errorf("%s and %s are two homes", pair[0], pair[1])
		}
	}
}

// --provider's cleanup that the home does not hear is said: the session
// may still be active, and Prism's Devices is where it is revoked.
func TestLogin_ProviderCleanupFailureIsSaid(t *testing.T) {
	home := newStubHome(t)
	other := newStubHome(t)
	home.failing["logout"] = true
	path := withContexts(t, "home", map[string]*config.Context{"home": {URL: home.URL}})
	home.onAction = func(action string) {
		if action == "device_poll" {
			moveContext(t, path, "home", other.URL)
		}
	}

	out, err := runLogin(t, t.Context(), "login", "--provider", "github")
	if !exitsOne(err) || strings.Contains(err.Error(), "the session was ended") ||
		!strings.Contains(err.Error(), "may still be active") || !strings.Contains(err.Error(), "Devices") {
		t.Fatalf("want the failed cleanup said, got %v\n%s", err, out)
	}
	if _, asked := home.call("logout"); !asked {
		t.Error("no cleanup was asked of the home")
	}
}

// A withdrawal the home does not hear, after the context moved, is said
// the same way rather than claimed.
func TestLogin_WithdrawalFailureIsSaid(t *testing.T) {
	home := newStubHome(t, "pending", "approved")
	other := newStubHome(t)
	home.failing["cli_cancel"] = true
	path := withContexts(t, "home", map[string]*config.Context{"home": {URL: home.URL}})
	var once sync.Once
	home.onAction = func(action string) {
		if action == "cli_poll" {
			once.Do(func() { moveContext(t, path, "home", other.URL) })
		}
	}

	out, err := runLogin(t, t.Context(), "login")
	if !exitsOne(err) || strings.Contains(err.Error(), "so it was withdrawn") ||
		!strings.Contains(err.Error(), "may still be active") {
		t.Fatalf("want the failed withdrawal said, got %v\n%s", err, out)
	}
}
