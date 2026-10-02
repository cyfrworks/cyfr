// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/cyfr/codex/internal/confirmation"
	"github.com/cyfr/codex/internal/mcp"
	"github.com/cyfr/codex/internal/prompt"
)

// The shared vector's secret and its ref (tests/fixtures/confirmation.json),
// which TestSharedSignal_AnswersTheVectorsRecord holds to the file: a secret
// spelled as the home spells one, cnf_ and 43 base64url characters.
const (
	pendingSecret = "cnf_AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
	pendingRef    = "cnr_RwUmgDNh5ufeCSEze6Mgzs_TKyc4u-HLi4RFA8i9XZ4"
	otherSecret   = "cnf_HyAhIiMkJSYnKCkqKywtLi8wMTIzNDU2Nzg5Ojs8PT4"
)

// signalVector is tests/fixtures/confirmation.json's confirmation_required
// signal, as the home's producers write it byte for byte, and the record's
// secret and ref.
type signalVector struct {
	Ref struct {
		ID  string `json:"id"`
		Ref string `json:"ref"`
	} `json:"ref"`
	Signal struct {
		Value   string `json:"value"`
		Message string `json:"message"`
		MCP     struct {
			Body string `json:"body"`
		} `json:"mcp"`
	} `json:"signal"`
}

var sharedSignal = sync.OnceValues(func() (*signalVector, error) {
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "tests", "fixtures", "confirmation.json"))
	if err != nil {
		return nil, err
	}
	var v signalVector
	if err := json.Unmarshal(raw, &v); err != nil {
		return nil, err
	}
	if v.Signal.Value == "" || v.Signal.MCP.Body == "" {
		return nil, errors.New("the shared vector carries no signal")
	}
	return &v, nil
})

func loadSignal(t *testing.T) *signalVector {
	t.Helper()
	v, err := sharedSignal()
	if err != nil {
		t.Fatalf("read the shared signal: %v", err)
	}
	return v
}

// value is the vector's {tag, payload}, decoded afresh for each caller.
func (v *signalVector) value(t *testing.T) (string, map[string]any) {
	t.Helper()
	var value struct {
		Tag     string         `json:"tag"`
		Payload map[string]any `json:"payload"`
	}
	if err := json.Unmarshal([]byte(v.Signal.Value), &value); err != nil {
		t.Fatalf("decode the shared signal's value: %v", err)
	}
	return value.Tag, value.Payload
}

// answer is the home's -33505 for a change waiting on the confirmation whose
// secret is id, expiring at expiresAt: the vector's own bytes for its own
// secret and expiry ("" keeps the vector's), and those bytes with the
// payload's id and expiry replaced otherwise. No id is a proxy that stripped
// error.data.
func (v *signalVector) answer(id, expiresAt string) (string, error) {
	if id == v.Ref.ID && expiresAt == "" {
		return v.Signal.MCP.Body, nil
	}
	decoder := json.NewDecoder(strings.NewReader(v.Signal.MCP.Body))
	decoder.UseNumber()
	var body map[string]any
	if err := decoder.Decode(&body); err != nil {
		return "", err
	}
	rpcErr, _ := body["error"].(map[string]any)
	data, _ := rpcErr["data"].(map[string]any)
	payload, _ := data["payload"].(map[string]any)
	if payload == nil {
		return "", fmt.Errorf("the shared signal's error carries no payload: %s", v.Signal.MCP.Body)
	}
	if id == "" {
		delete(rpcErr, "data")
	} else {
		payload["id"] = id
	}
	if expiresAt != "" {
		payload["expires_at"] = expiresAt
	}
	out, err := json.Marshal(body)
	return string(out), err
}

// soon is an expiry five minutes off, which no test's wait reaches.
func soon() string { return time.Now().Add(5 * time.Minute).UTC().Format(time.RFC3339) }

// cliServer stands in for the home: each tools/call is answered with the
// next of its answers (a cnf_ secret answers the shared vector's -33505
// naming it, anything else is a result's JSON text), and each request's
// params are kept.
type cliServer struct {
	*httptest.Server
	mu        sync.Mutex
	signal    *signalVector
	expiresAt string
	answers   []string
	requests  []map[string]any
}

// newCLIServer answers each pending confirmation expiring at expiresAt, ""
// for the vector's own expiry.
func newCLIServer(t *testing.T, expiresAt string, answers ...string) *cliServer {
	t.Helper()
	s := &cliServer{
		signal:    loadSignal(t),
		expiresAt: expiresAt,
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
			pending, err := s.signal.answer(answer, s.expiresAt)
			if err != nil {
				t.Errorf("the shared signal: %v", err)
			}
			// MCP over HTTP answers -33505 at 400, as it does -33502.
			w.WriteHeader(http.StatusBadRequest)
			io.WriteString(w, pending)
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
// The shared vector
// ---------------------------------------------------------------------------

// The signal the vector carries answers its record: the payload names the
// record's secret, whose ref is the record's, and an expiry the CLI reads.
func TestSharedSignal_AnswersTheVectorsRecord(t *testing.T) {
	v := loadSignal(t)
	if v.Ref.ID != pendingSecret || v.Ref.Ref != pendingRef {
		t.Fatalf("the vector's secret and ref are %q and %q", v.Ref.ID, v.Ref.Ref)
	}

	tag, payload := v.value(t)
	if tag != "confirmation_required" {
		t.Errorf("the vector's signal is %q", tag)
	}
	if id, _ := payload["id"].(string); id != pendingSecret || confirmation.Ref(id) != pendingRef {
		t.Errorf("the signal names %q, not the record's secret", payload["id"])
	}
	if _, ok := confirmationExpiry(payload); !ok {
		t.Errorf("the CLI cannot read the expiry the home writes: %v", payload["expires_at"])
	}
	if strings.Contains(v.Signal.Message, pendingSecret) {
		t.Errorf("the signal's sentence names the secret: %s", v.Signal.Message)
	}
}

// ---------------------------------------------------------------------------
// The sentence
// ---------------------------------------------------------------------------

// A command meeting the vector's -33505 ends in an error that names the
// record by its ref, says nothing was changed and sends the person to
// Prism: never success, never the generic failure, and never the secret.
func TestConfirmationRequired_RendersTheRefNeverTheSecret(t *testing.T) {
	srv := newCLIServer(t, "", pendingSecret)
	_, payload := loadSignal(t).value(t)
	operation, _ := payload["operation"].(string)
	expiresAt, _ := payload["expires_at"].(string)

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
	for _, want := range []string{pendingRef, "nothing was changed", "Prism", operation, "before " + expiresAt, "asking"} {
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
	stripped, err := loadSignal(t).answer("", "")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(stripped, `"data"`) {
		t.Fatalf("error.data was not stripped: %s", stripped)
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		io.WriteString(w, stripped)
	}))
	defer srv.Close()

	_, err = mcp.NewClient(srv.URL).CallTool(t.Context(), "vault", map[string]any{"action": "create"})
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

// The formatter alone, over the vector's payload: the operation, the ref of
// the payload's id and the expiry, as the wire carries them.
func TestFormatConsentError_ConfirmationRequired(t *testing.T) {
	tag, payload := loadSignal(t).value(t)
	text := formatConsentError(tag, payload)

	want := "Confirmation required: vault.create needs a fresh confirmation; nothing was changed.\n" +
		"  Confirm " + pendingRef + " in Prism before 2026-09-21T14:18:20.000000Z, where this key or client is named as the one asking."
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

// pendingAt is the vector's signal as the client reads it, waiting on the
// confirmation whose secret is id and expiring at expiresAt.
func pendingAt(t *testing.T, id string, expiresAt time.Time) *mcp.ConsentError {
	t.Helper()
	v := loadSignal(t)
	tag, payload := v.value(t)
	payload["id"] = id
	payload["expires_at"] = expiresAt.UTC().Format(time.RFC3339Nano)
	return &mcp.ConsentError{Tag: tag, Message: v.Signal.Message, Payload: payload}
}

// Off a terminal the wait ends at once with the signal, which the command
// prints before exiting 1, and says nothing itself.
func TestConfirmationWait_OffATerminalEndsAtOnce(t *testing.T) {
	wait, out := newWait(false, make(chan string), time.Now)
	pending := pendingAt(t, pendingSecret, time.Now().Add(time.Minute))

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
	pending := pendingAt(t, pendingSecret, time.Now().Add(-time.Second))

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
	pending := pendingAt(t, pendingSecret, time.Now().Add(time.Minute))

	done := make(chan error, 1)
	go func() { done <- wait.wait(t.Context(), pending, false) }()

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
	pending := pendingAt(t, pendingSecret, time.Now().Add(time.Minute))

	done := make(chan error, 1)
	go func() { done <- wait.wait(t.Context(), pending, true) }()
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
	pending := pendingAt(t, pendingSecret, time.Now().Add(100*time.Millisecond))

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
	pending := pendingAt(t, pendingSecret, time.Now().Add(time.Minute))

	done := make(chan error, 1)
	go func() { done <- wait.wait(ctx, pending, false) }()
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
	pending := pendingAt(t, pendingSecret, time.Now().Add(time.Minute))

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
	srv := newCLIServer(t, soon(), pendingSecret, pendingSecret, `{"entry":"created"}`)
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
	srv := newCLIServer(t, soon(), pendingSecret, otherSecret)
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
	srv := newCLIServer(t, "", pendingSecret)
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
