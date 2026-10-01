// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/cyfr/codex/internal/confirmation"
	"github.com/cyfr/codex/internal/mcp"
	"github.com/cyfr/codex/internal/prompt"
)

// The shared vector's secret and its ref (tests/fixtures/confirmation.json):
// a secret spelled as the home spells one, cnf_ and 43 base64url characters.
const (
	pendingSecret = "cnf_AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
	pendingRef    = "cnr_RwUmgDNh5ufeCSEze6Mgzs_TKyc4u-HLi4RFA8i9XZ4"
	otherSecret   = "cnf_HyAhIiMkJSYnKCkqKywtLi8wMTIzNDU2Nzg5Ojs8PT4"
)

// confirmationError is the server's -33505 for a change waiting on the
// confirmation whose secret is id, expiring at expiresAt: the sentence names
// no id, the payload carries it. No id is a proxy that stripped error.data.
func confirmationError(operation, id, expiresAt string) string {
	body := `{"jsonrpc":"2.0","id":1,"error":{"code":-33505,` +
		`"message":"Confirmation required: ` + operation + ` needs a fresh confirmation; nothing was changed."`
	if id != "" {
		body += `,"data":{"tag":"confirmation_required","payload":` +
			`{"id":"` + id + `","operation":"` + operation + `","expires_at":"` + expiresAt + `"}}`
	}
	return body + `}}`
}

// cliServer stands in for the home: each tools/call is answered with the
// next of its answers (a cnf_ secret answers -33505 naming it, anything else
// is a result's JSON text), and each request's params are kept.
type cliServer struct {
	*httptest.Server
	mu        sync.Mutex
	operation string
	expiresAt string
	answers   []string
	requests  []map[string]any
}

func newCLIServer(t *testing.T, operation string, answers ...string) *cliServer {
	t.Helper()
	s := &cliServer{
		operation: operation,
		expiresAt: time.Now().Add(5 * time.Minute).UTC().Format(time.RFC3339),
		answers:   answers,
	}
	s.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw, _ := io.ReadAll(r.Body)
		var req struct {
			Params map[string]any `json:"params"`
		}
		if err := json.Unmarshal(raw, &req); err != nil {
			t.Errorf("unreadable request: %v", err)
		}

		s.mu.Lock()
		s.requests = append(s.requests, req.Params)
		answer := `{}`
		if n := len(s.requests); n <= len(s.answers) {
			answer = s.answers[n-1]
		}
		s.mu.Unlock()

		w.Header().Set("Content-Type", "application/json")
		if strings.HasPrefix(answer, "cnf_") {
			w.WriteHeader(http.StatusBadRequest)
			io.WriteString(w, confirmationError(s.operation, answer, s.expiresAt))
			return
		}
		text, _ := json.Marshal(answer)
		io.WriteString(w, `{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":`+string(text)+`}]}}`)
	}))
	t.Cleanup(s.Close)
	return s
}

// repeats is the confirmation id each request carried in its _meta, "" for
// none.
func (s *cliServer) repeats() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	ids := make([]string, len(s.requests))
	for i, params := range s.requests {
		meta, _ := params["_meta"].(map[string]any)
		ids[i], _ = meta[mcp.ConfirmationIDKey].(string)
	}
	return ids
}

// arguments is what request i asked of its tool.
func (s *cliServer) arguments(i int) map[string]any {
	s.mu.Lock()
	defer s.mu.Unlock()
	args, _ := s.requests[i]["arguments"].(map[string]any)
	return args
}

func sameIDs(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// A terminal stands in for the person: interactive or not, and the lines
// they type, fed through enter.
type terminal struct {
	interactive bool
	lines       chan string
}

func (term *terminal) enter() { term.lines <- "" }

// onTerminal makes every client newClient builds in this test wait on term.
func onTerminal(t *testing.T, interactive bool) *terminal {
	t.Helper()
	term := &terminal{interactive: interactive, lines: make(chan string, 8)}

	savedTerminal, savedInput := confirmationTerminal, confirmationInput
	confirmationTerminal = func() bool { return term.interactive }
	confirmationInput = func() <-chan string { return term.lines }
	t.Cleanup(func() { confirmationTerminal, confirmationInput = savedTerminal, savedInput })
	return term
}

// ---------------------------------------------------------------------------
// The sentence
// ---------------------------------------------------------------------------

// A command meeting -33505 ends in an error that names the record by its
// ref, says nothing was changed and sends the person to Prism: never
// success, never the generic failure, and never the secret.
func TestConfirmationRequired_RendersTheRefNeverTheSecret(t *testing.T) {
	srv := newCLIServer(t, "vault.create", pendingSecret)

	result, err := mcp.NewClient(srv.URL).CallTool(t.Context(), "vault", map[string]any{"action": "create"})
	if err == nil {
		t.Fatalf("a confirmation_required answer read as success: %v", result)
	}
	if result != nil {
		t.Errorf("expected no result, got %v", result)
	}

	// What a command's RunE returns, and Execute prints before exiting non-zero.
	rendered := handleToolError(err, "Create failed")
	if rendered == nil {
		t.Fatal("handleToolError returned nil: the command would exit as success")
	}
	if errors.Is(rendered, mcp.ErrAuthRequired) {
		t.Errorf("a pending confirmation must not read as an auth problem: %v", rendered)
	}

	text := rendered.Error()
	for _, want := range []string{pendingRef, "nothing was changed", "Prism", "vault.create", "asking"} {
		if !strings.Contains(text, want) {
			t.Errorf("rendered output lacks %q:\n%s", want, text)
		}
	}
	if strings.Contains(text, "cnf_") {
		t.Errorf("rendered output shows the secret:\n%s", text)
	}
	if strings.HasPrefix(text, "Create failed") || strings.HasPrefix(text, "Failed") {
		t.Errorf("fell through to the generic failure:\n%s", text)
	}
}

// With error.data stripped the code still names the tag: the rendering
// still says nothing was changed and sends the person to Prism.
func TestConfirmationRequired_WithoutDataStillSendsThePersonToPrism(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		io.WriteString(w, confirmationError("vault.create", "", ""))
	}))
	defer srv.Close()

	_, err := mcp.NewClient(srv.URL).CallTool(t.Context(), "vault", map[string]any{"action": "create"})
	if err == nil {
		t.Fatal("a confirmation_required answer read as success")
	}

	rendered := handleToolError(err, "Create failed")
	if rendered == nil {
		t.Fatal("handleToolError returned nil: the command would exit as success")
	}

	text := rendered.Error()
	for _, want := range []string{"Confirmation required", "nothing was changed", "Confirm it in Prism"} {
		if !strings.Contains(text, want) {
			t.Errorf("rendered output lacks %q:\n%s", want, text)
		}
	}
}

// The formatter alone: the operation, the ref of the payload's id and the
// expiry, as the wire carries them.
func TestFormatConsentError_ConfirmationRequired(t *testing.T) {
	text := formatConsentError("confirmation_required", map[string]any{
		"id":         pendingSecret,
		"operation":  "vault.create",
		"expires_at": "2026-09-29T12:05:00Z",
	})

	want := "Confirmation required: vault.create needs a fresh confirmation; nothing was changed.\n" +
		"  Confirm " + pendingRef + " in Prism before 2026-09-29T12:05:00Z, where this key or client is named as the one asking."
	if text != want {
		t.Errorf("got:\n%s\nwant:\n%s", text, want)
	}
	if confirmation.Ref(pendingSecret) != pendingRef {
		t.Error("the shared vector's ref is not the secret's")
	}
}

// ---------------------------------------------------------------------------
// The wait
// ---------------------------------------------------------------------------

// A wait over a fake terminal: its output and the lines it reads.
func newWait(interactive bool, lines chan string, now func() time.Time) (*confirmationWait, *bytes.Buffer) {
	out := &bytes.Buffer{}
	return &confirmationWait{
		out:         out,
		interactive: func() bool { return interactive },
		lines:       func() <-chan string { return lines },
		now:         now,
	}, out
}

func pendingAt(id string, expiresAt time.Time) *mcp.ConsentError {
	return &mcp.ConsentError{
		Tag:     "confirmation_required",
		Message: "Confirmation required: vault.create needs a fresh confirmation; nothing was changed.",
		Payload: map[string]any{
			"id":         id,
			"operation":  "vault.create",
			"expires_at": expiresAt.UTC().Format(time.RFC3339Nano),
		},
	}
}

// Off a terminal the wait ends at once with the signal, which the command
// prints before exiting 1, and says nothing itself.
func TestConfirmationWait_OffATerminalEndsAtOnce(t *testing.T) {
	wait, out := newWait(false, make(chan string), time.Now)
	pending := pendingAt(pendingSecret, time.Now().Add(time.Minute))

	if err := wait.wait(t.Context(), pending, false); err != pending {
		t.Fatalf("expected the signal itself, got %v", err)
	}
	if out.Len() != 0 {
		t.Errorf("an ended wait printed:\n%s", out)
	}
}

// Past the record's expiry there is nothing left to wait for.
func TestConfirmationWait_PastTheExpiryEndsAtOnce(t *testing.T) {
	wait, out := newWait(true, make(chan string), time.Now)
	pending := pendingAt(pendingSecret, time.Now().Add(-time.Second))

	if err := wait.wait(t.Context(), pending, false); err != pending {
		t.Fatalf("expected the signal itself, got %v", err)
	}
	if out.Len() != 0 {
		t.Errorf("an ended wait printed:\n%s", out)
	}
}

// On a terminal the wait prints the sentence, naming the ref, and the
// instruction, and an Enter repeats.
func TestConfirmationWait_EnterRepeats(t *testing.T) {
	lines := make(chan string)
	wait, out := newWait(true, lines, time.Now)

	done := make(chan error, 1)
	go func() { done <- wait.wait(t.Context(), pendingAt(pendingSecret, time.Now().Add(time.Minute)), false) }()

	lines <- ""
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("an Enter must repeat, got %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the wait did not answer the Enter")
	}

	text := out.String()
	for _, want := range []string{pendingRef, "Prism", "Press Enter once confirmed, Ctrl-C to leave it"} {
		if !strings.Contains(text, want) {
			t.Errorf("the wait's output lacks %q:\n%s", want, text)
		}
	}
	if strings.Contains(text, "cnf_") {
		t.Errorf("the wait shows the secret:\n%s", text)
	}
}

// A repeat answered with the same id is still waiting: the wait says so, by
// the ref, and waits again.
func TestConfirmationWait_AgainSaysItIsStillWaiting(t *testing.T) {
	lines := make(chan string)
	wait, out := newWait(true, lines, time.Now)

	done := make(chan error, 1)
	go func() { done <- wait.wait(t.Context(), pendingAt(pendingSecret, time.Now().Add(time.Minute)), true) }()
	lines <- ""

	if err := <-done; err != nil {
		t.Fatalf("an Enter must repeat, got %v", err)
	}
	text := out.String()
	if !strings.Contains(text, "Not confirmed yet: "+pendingRef+" is still waiting") {
		t.Errorf("the wait does not say it is still waiting:\n%s", text)
	}
	if strings.Contains(text, "cnf_") {
		t.Errorf("the wait shows the secret:\n%s", text)
	}
}

// The wait ends at the record's expiry, with the signal: nothing repeats.
func TestConfirmationWait_EndsAtTheExpiry(t *testing.T) {
	wait, _ := newWait(true, make(chan string), time.Now)
	pending := pendingAt(pendingSecret, time.Now().Add(100*time.Millisecond))

	start := time.Now()
	if err := wait.wait(t.Context(), pending, false); err != pending {
		t.Fatalf("expected the signal at the expiry, got %v", err)
	}
	if elapsed := time.Since(start); elapsed > 5*time.Second {
		t.Errorf("the wait outlived its expiry by %v", elapsed)
	}
}

// Ctrl-C leaves it: the command exits 130 and prints nothing more.
func TestConfirmationWait_CtrlCLeavesIt(t *testing.T) {
	wait, _ := newWait(true, make(chan string), time.Now)
	ctx, cancel := context.WithCancel(t.Context())

	done := make(chan error, 1)
	go func() { done <- wait.wait(ctx, pendingAt(pendingSecret, time.Now().Add(time.Minute)), false) }()
	cancel()

	err := <-done
	if !errors.Is(err, prompt.ErrAborted) {
		t.Fatalf("expected the abort, got %v", err)
	}
	if rendered := handleToolError(err); !errors.Is(rendered, prompt.ErrAborted) {
		t.Errorf("the command must exit 130 silently, got %v", rendered)
	}
}

// At the end of input no Enter can come: the wait ends with the signal.
func TestConfirmationWait_EndOfInputEndsIt(t *testing.T) {
	lines := make(chan string)
	close(lines)
	wait, _ := newWait(true, lines, time.Now)
	pending := pendingAt(pendingSecret, time.Now().Add(time.Minute))

	if err := wait.wait(t.Context(), pending, false); err != pending {
		t.Fatalf("expected the signal, got %v", err)
	}
}

// ---------------------------------------------------------------------------
// Every command's tool call
// ---------------------------------------------------------------------------

// Through the client every command builds: on a terminal, a repeat before
// the proof waits again under the same id, and the repeat after it
// completes; the secret rides _meta alone and is never printed.
func TestNewClient_WaitsAndRepeatsOnATerminal(t *testing.T) {
	term := onTerminal(t, true)
	srv := newCLIServer(t, "vault.create", pendingSecret, pendingSecret, `{"entry":"created"}`)
	flagURL = srv.URL
	t.Cleanup(func() { flagURL = "" })

	var result map[string]any
	var err error
	out := captureStdout(t, func() {
		done := make(chan struct{})
		go func() {
			defer close(done)
			result, err = newClient().CallTool(t.Context(), "vault", map[string]any{"action": "create", "name": "prod"})
		}()
		term.enter()
		term.enter()
		<-done
	})

	if err != nil {
		t.Fatalf("the confirmed repeat failed: %v", err)
	}
	if result["entry"] != "created" {
		t.Errorf("expected the repeat's result, got %v", result)
	}
	if got := srv.repeats(); !sameIDs(got, []string{"", pendingSecret, pendingSecret}) {
		t.Errorf("the first call carries no id and each repeat the one id, got %q", got)
	}
	for i := range 3 {
		if args := srv.arguments(i); args["name"] != "prod" || args["action"] != "create" {
			t.Errorf("request %d asked another change: %v", i, args)
		}
		if strings.Contains(str(srv.arguments(i)), "cnf_") {
			t.Errorf("request %d carried the secret in its arguments", i)
		}
	}

	for _, want := range []string{pendingRef, "Press Enter once confirmed", "still waiting"} {
		if !strings.Contains(out, want) {
			t.Errorf("the output lacks %q:\n%s", want, out)
		}
	}
	if strings.Contains(out, "cnf_") {
		t.Errorf("the output shows the secret:\n%s", out)
	}
}

// A repeat answered with a new id ends the wait with that answer: it is a
// record this wait never showed, and nothing is repeated under it.
func TestNewClient_ANewIdEndsTheWait(t *testing.T) {
	term := onTerminal(t, true)
	srv := newCLIServer(t, "vault.create", pendingSecret, otherSecret)
	flagURL = srv.URL
	t.Cleanup(func() { flagURL = "" })

	var err error
	out := captureStdout(t, func() {
		done := make(chan struct{})
		go func() {
			defer close(done)
			_, err = newClient().CallTool(t.Context(), "vault", map[string]any{"action": "create"})
		}()
		term.enter()
		<-done
	})

	rendered := handleToolError(err)
	if rendered == nil || !strings.Contains(rendered.Error(), confirmation.Ref(otherSecret)) {
		t.Fatalf("expected the new record's sentence, got %v", rendered)
	}
	if got := srv.repeats(); !sameIDs(got, []string{"", pendingSecret}) {
		t.Errorf("one repeat, then the answer: got %q", got)
	}
	if strings.Contains(out+rendered.Error(), "cnf_") {
		t.Errorf("the output shows a secret:\n%s\n%s", out, rendered)
	}
}

// Off a terminal nothing is repeated: one request, the sentence, an error.
func TestNewClient_OffATerminalRepeatsNothing(t *testing.T) {
	onTerminal(t, false)
	srv := newCLIServer(t, "vault.create", pendingSecret)
	flagURL = srv.URL
	t.Cleanup(func() { flagURL = "" })

	var err error
	out := captureStdout(t, func() {
		_, err = newClient().CallTool(t.Context(), "vault", map[string]any{"action": "create"})
	})

	rendered := handleToolError(err)
	if rendered == nil || !strings.Contains(rendered.Error(), pendingRef) {
		t.Fatalf("expected the sentence naming the ref, got %v", rendered)
	}
	if got := srv.repeats(); !sameIDs(got, []string{""}) {
		t.Errorf("nothing is repeated, got %q", got)
	}
	if strings.Contains(out+rendered.Error(), "cnf_") {
		t.Errorf("the output shows the secret:\n%s\n%s", out, rendered)
	}
}
