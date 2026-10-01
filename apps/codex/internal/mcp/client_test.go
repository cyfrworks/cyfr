// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package mcp

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
)

func TestNewClient(t *testing.T) {
	c := NewClient("http://example.com")
	if c.BaseURL != "http://example.com" {
		t.Errorf("expected BaseURL 'http://example.com', got %q", c.BaseURL)
	}
	if c.SessionID != "" {
		t.Errorf("expected empty SessionID, got %q", c.SessionID)
	}
}

func TestDiscover_AcceptsMatchingVersion(t *testing.T) {
	var requestCount int
	var reqBody []byte

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requestCount++
		reqBody, _ = io.ReadAll(r.Body)
		// A server-minted session id must be ignored if one ever appears.
		w.Header().Set("Mcp-Session-Id", "sess-abc123")
		resp := JSONRPCResponse{
			JSONRPC: "2.0",
			ID:      1,
			Result: map[string]any{
				"supportedVersions": []string{protocolVersion},
				"capabilities":      map[string]any{},
				"_meta":             map[string]any{"io.modelcontextprotocol/serverInfo": map[string]any{"name": "cyfr", "version": "0.1.0"}},
			},
		}
		json.NewEncoder(w).Encode(resp)
	}))
	defer srv.Close()

	c := NewClient(srv.URL)
	if err := c.Discover(t.Context()); err != nil {
		t.Fatalf("Discover failed: %v", err)
	}

	// One request, no handshake follow-up notification.
	if requestCount != 1 {
		t.Fatalf("expected 1 request, got %d", requestCount)
	}
	if c.SessionID != "" {
		t.Errorf("expected no captured SessionID, got %q", c.SessionID)
	}

	var sent map[string]any
	if err := json.Unmarshal(reqBody, &sent); err != nil {
		t.Fatalf("failed to parse request body: %v", err)
	}
	if sent["method"] != "server/discover" {
		t.Errorf("expected server/discover, got %v", sent["method"])
	}

	// Every request declares its own protocol version — there is no handshake
	// that could have established it.
	params, _ := sent["params"].(map[string]any)
	meta, _ := params["_meta"].(map[string]any)
	if meta["io.modelcontextprotocol/protocolVersion"] != protocolVersion {
		t.Errorf("expected _meta protocolVersion %q, got %v", protocolVersion, meta)
	}
}

func TestDiscover_RejectsUnsupportedProtocol(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		resp := JSONRPCResponse{
			JSONRPC: "2.0",
			ID:      1,
			Result: map[string]any{
				"supportedVersions": []string{"2099-01-01"},
				"capabilities":      map[string]any{},
				"_meta":             map[string]any{"io.modelcontextprotocol/serverInfo": map[string]any{"name": "future-server", "version": "9.9.9"}},
			},
		}
		json.NewEncoder(w).Encode(resp)
	}))
	defer srv.Close()

	c := NewClient(srv.URL)
	err := c.Discover(t.Context())
	if err == nil {
		t.Fatal("expected error for unsupported protocol version")
	}
	if !errors.Is(err, ErrUnsupportedProtocol) {
		t.Errorf("expected ErrUnsupportedProtocol, got %v", err)
	}
}

func TestCallTool_TextContentJSON(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		resp := JSONRPCResponse{
			JSONRPC: "2.0",
			ID:      1,
			Result: map[string]any{
				"content": []map[string]any{
					{"type": "text", "text": `{"status":"ok","count":42}`},
				},
			},
		}
		json.NewEncoder(w).Encode(resp)
	}))
	defer srv.Close()

	c := NewClient(srv.URL)
	result, err := c.CallTool(t.Context(), "test-tool", nil)
	if err != nil {
		t.Fatalf("CallTool failed: %v", err)
	}
	if result["status"] != "ok" {
		t.Errorf("expected status 'ok', got %v", result["status"])
	}
	// JSON numbers unmarshal as float64
	if result["count"] != float64(42) {
		t.Errorf("expected count 42, got %v", result["count"])
	}
}

func TestCallTool_PlainText(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		resp := JSONRPCResponse{
			JSONRPC: "2.0",
			ID:      1,
			Result: map[string]any{
				"content": []map[string]any{
					{"type": "text", "text": "hello world"},
				},
			},
		}
		json.NewEncoder(w).Encode(resp)
	}))
	defer srv.Close()

	c := NewClient(srv.URL)
	result, err := c.CallTool(t.Context(), "test-tool", nil)
	if err != nil {
		t.Fatalf("CallTool failed: %v", err)
	}
	if result["text"] != "hello world" {
		t.Errorf("expected text 'hello world', got %v", result["text"])
	}
}

func TestCallTool_IsError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		resp := JSONRPCResponse{
			JSONRPC: "2.0",
			ID:      1,
			Result: map[string]any{
				"content": []map[string]any{
					{"type": "text", "text": "permission denied"},
				},
				"isError": true,
			},
		}
		json.NewEncoder(w).Encode(resp)
	}))
	defer srv.Close()

	c := NewClient(srv.URL)
	_, err := c.CallTool(t.Context(), "test-tool", nil)
	if err == nil {
		t.Fatal("expected error for isError response")
	}
	if !strings.Contains(err.Error(), "permission denied") {
		t.Errorf("expected error containing 'permission denied', got %q", err.Error())
	}
}

func TestCallTool_RPCError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		resp := JSONRPCResponse{
			JSONRPC: "2.0",
			ID:      1,
			Error:   &JSONRPCError{Code: -32600, Message: "invalid request"},
		}
		json.NewEncoder(w).Encode(resp)
	}))
	defer srv.Close()

	c := NewClient(srv.URL)
	_, err := c.CallTool(t.Context(), "test-tool", nil)
	if err == nil {
		t.Fatal("expected error for RPC error response")
	}
	if !strings.Contains(err.Error(), "invalid request") {
		t.Errorf("expected error containing 'invalid request', got %q", err.Error())
	}
}

// A 404 denotes an unimplemented method and must not produce a login hint.
func TestCallTool_UnknownMethodIsNotASessionProblem(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotFound)
		resp := JSONRPCResponse{
			JSONRPC: "2.0",
			ID:      1,
			Error:   &JSONRPCError{Code: -32601, Message: "Unknown method: tasks/list"},
		}
		json.NewEncoder(w).Encode(resp)
	}))
	defer srv.Close()

	c := NewClient(srv.URL)
	c.SessionID = "a-perfectly-good-credential"
	_, err := c.CallTool(t.Context(), "test-tool", nil)
	if err == nil {
		t.Fatal("expected an error")
	}
	if errors.Is(err, ErrAuthRequired) {
		t.Errorf("a missing method must not be reported as an auth problem, got %v", err)
	}
	if !strings.Contains(err.Error(), "Unknown method") {
		t.Errorf("expected the server's message to survive, got %q", err.Error())
	}
}

// -33001 is the one auth sentinel the server still emits.
func TestCallTool_AuthRequired(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
		resp := JSONRPCResponse{
			JSONRPC: "2.0",
			ID:      1,
			Error:   &JSONRPCError{Code: -33001, Message: "Authentication required."},
		}
		json.NewEncoder(w).Encode(resp)
	}))
	defer srv.Close()

	c := NewClient(srv.URL)
	_, err := c.CallTool(t.Context(), "test-tool", nil)
	if !errors.Is(err, ErrAuthRequired) {
		t.Errorf("expected ErrAuthRequired, got %v", err)
	}
}

// A sensitive change answers -33505: never a success, and the pending
// confirmation's secret id survives, in the payload alone, to the wait that
// repeats under it. The body is the one the server writes, a JSON-RPC error
// at HTTP 400, whose sentence names no id.
func TestCallTool_ConfirmationRequired(t *testing.T) {
	const id = secretA
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		io.WriteString(w, confirmationBody(id))
	}))
	defer srv.Close()

	c := NewClient(srv.URL)
	result, err := c.CallTool(t.Context(), "vault", map[string]any{"action": "create"})
	if err == nil {
		t.Fatalf("a confirmation_required answer must not read as success, got %v", result)
	}
	if result != nil {
		t.Errorf("expected no result, got %v", result)
	}
	if errors.Is(err, ErrAuthRequired) {
		t.Errorf("a pending confirmation is not an auth problem, got %v", err)
	}

	var ce *ConsentError
	if !errors.As(err, &ce) {
		t.Fatalf("expected a ConsentError, got %T: %v", err, err)
	}
	if ce.Tag != "confirmation_required" {
		t.Errorf("expected tag confirmation_required, got %q", ce.Tag)
	}
	if got, _ := ce.Payload["id"].(string); got != id {
		t.Errorf("expected the confirmation id %q in the payload, got %q", id, got)
	}
	if got, _ := ce.Payload["operation"].(string); got != "vault.create" {
		t.Errorf("expected the operation in the payload, got %q", got)
	}
	if strings.Contains(err.Error(), id) {
		t.Errorf("the error's text is the server's sentence, which names no id, got %q", err.Error())
	}
}

// Every consent code is typed, and names its tag even when a proxy stripped
// error.data.
func TestCallTool_ConsentCodesNameTheirTag(t *testing.T) {
	want := map[int]string{
		-33501: "setup_required",
		-33502: "consent_required",
		-33503: "consent_conflict",
		-33504: "restart_required",
		-33505: "confirmation_required",
	}
	if len(consentTagByCode) != len(want) {
		t.Fatalf("consentTagByCode has %d codes, want %d", len(consentTagByCode), len(want))
	}

	for code, tag := range want {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.WriteHeader(http.StatusBadRequest)
			json.NewEncoder(w).Encode(JSONRPCResponse{
				JSONRPC: "2.0",
				ID:      1,
				Error:   &JSONRPCError{Code: code, Message: "signal"},
			})
		}))

		_, err := NewClient(srv.URL).CallTool(t.Context(), "test-tool", nil)
		srv.Close()

		var ce *ConsentError
		if !errors.As(err, &ce) {
			t.Errorf("%d: expected a ConsentError, got %T: %v", code, err, err)
			continue
		}
		if ce.Tag != tag {
			t.Errorf("%d: expected tag %q, got %q", code, tag, ce.Tag)
		}
	}
}

func TestCallTool_Bare404(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotFound)
		w.Write([]byte("Not Found"))
	}))
	defer srv.Close()

	c := NewClient(srv.URL)
	_, err := c.CallTool(t.Context(), "test-tool", nil)
	if err == nil {
		t.Fatal("expected error for bare 404")
	}
	if !strings.Contains(err.Error(), "HTTP 404") {
		t.Errorf("expected a plain HTTP error, got %q", err.Error())
	}
}

func TestClose_SendsNothing(t *testing.T) {
	var anyRequest bool

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		anyRequest = true
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	c := NewClient(srv.URL)
	c.SessionID = "sess-to-close"

	if err := c.Close(); err != nil {
		t.Fatalf("Close failed: %v", err)
	}
	// There is no server-side session to terminate, so Close talks to nobody —
	// the credential is revoked by logging out, not by closing a client.
	if anyRequest {
		t.Error("expected Close to send no request")
	}
	if c.SessionID != "" {
		t.Errorf("expected SessionID to be cleared, got %q", c.SessionID)
	}
}

func TestClose_NoSession(t *testing.T) {
	c := NewClient("http://example.com")
	// Close with no session should be a no-op
	if err := c.Close(); err != nil {
		t.Fatalf("Close with no session should not error, got: %v", err)
	}
}

func TestCallTool_HTTPError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		w.Write([]byte("internal server error"))
	}))
	defer srv.Close()

	c := NewClient(srv.URL)
	_, err := c.CallTool(t.Context(), "test-tool", nil)
	if err == nil {
		t.Fatal("expected error for HTTP 500")
	}
	if !strings.Contains(err.Error(), "HTTP 500") {
		t.Errorf("expected error containing 'HTTP 500', got %q", err.Error())
	}
}

func TestListTools(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		resp := JSONRPCResponse{
			JSONRPC: "2.0",
			ID:      1,
			Result: map[string]any{
				"tools": []map[string]any{
					{"name": "tool-a", "description": "Tool A"},
					{"name": "tool-b", "description": "Tool B"},
				},
			},
		}
		json.NewEncoder(w).Encode(resp)
	}))
	defer srv.Close()

	c := NewClient(srv.URL)
	tools, err := c.ListTools(t.Context())
	if err != nil {
		t.Fatalf("ListTools failed: %v", err)
	}
	if len(tools) != 2 {
		t.Fatalf("expected 2 tools, got %d", len(tools))
	}
	if tools[0].Name != "tool-a" {
		t.Errorf("expected first tool 'tool-a', got %q", tools[0].Name)
	}
	if tools[1].Name != "tool-b" {
		t.Errorf("expected second tool 'tool-b', got %q", tools[1].Name)
	}
}

func TestCallTool_NilArgsSerialized(t *testing.T) {
	var receivedBody []byte

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		receivedBody, _ = io.ReadAll(r.Body)
		resp := JSONRPCResponse{
			JSONRPC: "2.0",
			ID:      1,
			Result: map[string]any{
				"content": []map[string]any{
					{"type": "text", "text": `{"ok":true}`},
				},
			},
		}
		json.NewEncoder(w).Encode(resp)
	}))
	defer srv.Close()

	c := NewClient(srv.URL)
	_, err := c.CallTool(t.Context(), "test-tool", nil)
	if err != nil {
		t.Fatalf("CallTool failed: %v", err)
	}

	// Verify arguments is present as empty object, not omitted
	var raw map[string]any
	if err := json.Unmarshal(receivedBody, &raw); err != nil {
		t.Fatalf("failed to parse request body: %v", err)
	}
	params, ok := raw["params"].(map[string]any)
	if !ok {
		t.Fatalf("expected params to be object, got %T", raw["params"])
	}
	args, hasArgs := params["arguments"]
	if !hasArgs {
		t.Fatal("expected 'arguments' field to be present in params")
	}
	argsMap, ok := args.(map[string]any)
	if !ok {
		t.Fatalf("expected arguments to be object, got %T", args)
	}
	if len(argsMap) != 0 {
		t.Errorf("expected empty arguments map, got %v", argsMap)
	}
}

func TestRoutingHeaders_MirrorTheBody(t *testing.T) {
	var gotMethod, gotName string

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotMethod = r.Header.Get("Mcp-Method")
		gotName = r.Header.Get("Mcp-Name")
		json.NewEncoder(w).Encode(JSONRPCResponse{JSONRPC: "2.0", ID: 1, Result: map[string]any{}})
	}))
	defer srv.Close()

	c := NewClient(srv.URL)
	_, _ = c.CallTool(t.Context(), "system", map[string]any{"action": "status"})

	if gotMethod != "tools/call" {
		t.Errorf("expected Mcp-Method tools/call, got %q", gotMethod)
	}
	// The server refuses a header that disagrees with the body, so the tool name
	// must be mirrored exactly.
	if gotName != "system" {
		t.Errorf("expected Mcp-Name system, got %q", gotName)
	}
}

func TestEncodeHeaderValue_Sentinel(t *testing.T) {
	if got := encodeHeaderValue("plain-name"); got != "plain-name" {
		t.Errorf("expected plain passthrough, got %q", got)
	}

	// Non-ASCII cannot travel as a plain header value.
	got := encodeHeaderValue("naïve")
	if !strings.HasPrefix(got, "=?base64?") || !strings.HasSuffix(got, "?=") {
		t.Errorf("expected sentinel encoding, got %q", got)
	}

	// A value that merely looks like the sentinel must be encoded too, or it
	// would be decoded into something else at the far end.
	if got := encodeHeaderValue("=?base64?nope?="); got == "=?base64?nope?=" {
		t.Error("expected sentinel-looking value to be re-encoded")
	}
}

func TestRequestHeaders(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Verify headers
		if ct := r.Header.Get("Content-Type"); ct != "application/json" {
			t.Errorf("expected Content-Type 'application/json', got %q", ct)
		}
		if accept := r.Header.Get("Accept"); accept != "application/json, text/event-stream" {
			t.Errorf("expected Accept 'application/json, text/event-stream', got %q", accept)
		}
		if pv := r.Header.Get("MCP-Protocol-Version"); pv != protocolVersion {
			t.Errorf("expected MCP-Protocol-Version %q, got %q", protocolVersion, pv)
		}
		// The credential travels in Authorization on every request; no
		// protocol session header is sent.
		if auth := r.Header.Get("Authorization"); auth != "Bearer my-session" {
			t.Errorf("expected Authorization 'Bearer my-session', got %q", auth)
		}
		if sid := r.Header.Get("MCP-Session-Id"); sid != "" {
			t.Errorf("expected no MCP-Session-Id header, got %q", sid)
		}

		// Verify request body is valid JSON-RPC
		body, _ := io.ReadAll(r.Body)
		var req JSONRPCRequest
		if err := json.Unmarshal(body, &req); err != nil {
			t.Errorf("invalid JSON-RPC request: %v", err)
		}
		if req.JSONRPC != "2.0" {
			t.Errorf("expected jsonrpc '2.0', got %q", req.JSONRPC)
		}

		resp := JSONRPCResponse{
			JSONRPC: "2.0",
			ID:      req.ID,
			Result: map[string]any{
				"tools": []any{},
			},
		}
		json.NewEncoder(w).Encode(resp)
	}))
	defer srv.Close()

	c := NewClient(srv.URL)
	c.SessionID = "my-session"
	_, _ = c.ListTools(t.Context())
}

// ---------------------------------------------------------------------------
// The repeat of a change that waits for a fresh confirmation
// ---------------------------------------------------------------------------

// Two secrets, spelled as the home spells one: cnf_ and 43 base64url
// characters.
const (
	secretA = "cnf_AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
	secretB = "cnf_HyAhIiMkJSYnKCkqKywtLi8wMTIzNDU2Nzg5Ojs8PT4"
)

// confirmationBody is the server's -33505 for a change waiting on the
// confirmation whose secret is id: the sentence names no id, the payload
// carries it.
func confirmationBody(id string) string {
	return `{"jsonrpc":"2.0","id":1,"error":{"code":-33505,` +
		`"message":"Confirmation required: vault.create needs a fresh confirmation; nothing was changed.",` +
		`"data":{"tag":"confirmation_required","payload":{"id":"` + id +
		`","operation":"vault.create","expires_at":"2099-01-01T00:00:00Z"}}}}`
}

// scriptedServer answers each tools/call with the next of its answers (a
// confirmation secret answers -33505 naming it, "auth" an auth refusal,
// anything else a tool result) and records each request's params.
type scriptedServer struct {
	*httptest.Server
	mu       sync.Mutex
	answers  []string
	requests []map[string]any
}

func newScriptedServer(t *testing.T, answers ...string) *scriptedServer {
	t.Helper()
	s := &scriptedServer{answers: answers}
	s.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		var req struct {
			Params map[string]any `json:"params"`
		}
		if err := json.Unmarshal(body, &req); err != nil {
			t.Errorf("unreadable request: %v", err)
		}

		s.mu.Lock()
		s.requests = append(s.requests, req.Params)
		answer := "ok"
		if n := len(s.requests); n <= len(s.answers) {
			answer = s.answers[n-1]
		}
		s.mu.Unlock()

		w.Header().Set("Content-Type", "application/json")
		switch {
		case strings.HasPrefix(answer, "cnf_"):
			w.WriteHeader(http.StatusBadRequest)
			io.WriteString(w, confirmationBody(answer))
		case answer == "auth":
			w.WriteHeader(http.StatusUnauthorized)
			io.WriteString(w, `{"jsonrpc":"2.0","id":1,"error":{"code":-33001,"message":"Not signed in"}}`)
		default:
			io.WriteString(w, `{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"{\"entry\":\"created\"}"}]}}`)
		}
	}))
	t.Cleanup(s.Close)
	return s
}

// sent is the confirmation id each request carried in its _meta, "" for
// none. Every request must be the first one's call: the same tool and the
// same arguments.
func (s *scriptedServer) sent(t *testing.T) []string {
	t.Helper()
	s.mu.Lock()
	defer s.mu.Unlock()

	ids := make([]string, len(s.requests))
	first, _ := json.Marshal(s.requests[0]["arguments"])
	for i, params := range s.requests {
		meta, _ := params["_meta"].(map[string]any)
		ids[i], _ = meta[ConfirmationIDKey].(string)
		if args, _ := json.Marshal(params["arguments"]); string(args) != string(first) {
			t.Errorf("request %d repeated other arguments: %s, not %s", i, args, first)
		}
		if name, _ := params["name"].(string); name != "vault" {
			t.Errorf("request %d called %q, not the same tool", i, name)
		}
	}
	return ids
}

// confirmer records what the wait was asked and answers from its script: nil
// repeats, an error ends the wait.
type confirmer struct {
	asked   []string
	answers []error
}

func (c *confirmer) confirm(_ context.Context, pending *ConsentError, again bool) error {
	id, _ := pending.Payload["id"].(string)
	label := id
	if again {
		label = "again:" + id
	}
	c.asked = append(c.asked, label)
	if len(c.answers) == 0 {
		return nil
	}
	answer := c.answers[0]
	c.answers = c.answers[1:]
	return answer
}

func equal(a, b []string) bool {
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

// Once the person confirmed, the same call is sent again under the signal's
// id, in _meta and never in the arguments, and completes.
func TestCallTool_RepeatsTheSameCallUnderTheIdInMeta(t *testing.T) {
	srv := newScriptedServer(t, secretA, "ok")
	waited := &confirmer{}
	c := NewClient(srv.URL)
	c.Confirm = waited.confirm

	result, err := c.CallTool(t.Context(), "vault", map[string]any{"action": "create", "name": "prod"})
	if err != nil {
		t.Fatalf("the confirmed repeat failed: %v", err)
	}
	if result["entry"] != "created" {
		t.Errorf("expected the repeat's result, got %v", result)
	}

	if got := srv.sent(t); !equal(got, []string{"", secretA}) {
		t.Errorf("the first call carries no id and the repeat its id, got %q", got)
	}
	if !equal(waited.asked, []string{secretA}) {
		t.Errorf("the wait was asked %q", waited.asked)
	}

	srv.mu.Lock()
	defer srv.mu.Unlock()
	if args, _ := json.Marshal(srv.requests[1]["arguments"]); strings.Contains(string(args), secretA) {
		t.Errorf("the id rode the arguments: %s", args)
	}
}

// A repeat answered with the same id came before the proof: the record is
// still waiting, so the wait is asked again, and the next repeat completes.
func TestCallTool_TheSameIdIsStillWaiting(t *testing.T) {
	srv := newScriptedServer(t, secretA, secretA, "ok")
	waited := &confirmer{}
	c := NewClient(srv.URL)
	c.Confirm = waited.confirm

	if _, err := c.CallTool(t.Context(), "vault", map[string]any{"action": "create"}); err != nil {
		t.Fatalf("the confirmed repeat failed: %v", err)
	}
	if got := srv.sent(t); !equal(got, []string{"", secretA, secretA}) {
		t.Errorf("each repeat carries the one id, got %q", got)
	}
	if !equal(waited.asked, []string{secretA, "again:" + secretA}) {
		t.Errorf("the wait was asked %q", waited.asked)
	}
}

// Any other answer ends the wait as that answer: a new id is a new record,
// which this wait never confirmed, and is not repeated.
func TestCallTool_AnotherAnswerEndsTheWait(t *testing.T) {
	for name, tc := range map[string]struct {
		answers []string
		check   func(t *testing.T, err error)
	}{
		"a new id": {
			answers: []string{secretA, secretB},
			check: func(t *testing.T, err error) {
				pending, id := pendingConfirmation(err)
				if pending == nil || id != secretB {
					t.Errorf("expected the new record's answer, got %v", err)
				}
			},
		},
		"an auth refusal": {
			answers: []string{secretA, "auth"},
			check: func(t *testing.T, err error) {
				if !errors.Is(err, ErrAuthRequired) {
					t.Errorf("expected the refusal itself, got %v", err)
				}
			},
		},
	} {
		t.Run(name, func(t *testing.T) {
			srv := newScriptedServer(t, tc.answers...)
			waited := &confirmer{}
			c := NewClient(srv.URL)
			c.Confirm = waited.confirm

			_, err := c.CallTool(t.Context(), "vault", map[string]any{"action": "create"})
			tc.check(t, err)
			if got := srv.sent(t); !equal(got, []string{"", secretA}) {
				t.Errorf("one repeat, then the answer: got %q", got)
			}
			if len(waited.asked) != 1 {
				t.Errorf("the wait was asked %q", waited.asked)
			}
		})
	}
}

// A wait that ends repeats nothing: the call answers the wait's own error.
func TestCallTool_AWaitThatEndsRepeatsNothing(t *testing.T) {
	srv := newScriptedServer(t, secretA)
	left := errors.New("left it")
	c := NewClient(srv.URL)
	c.Confirm = (&confirmer{answers: []error{left}}).confirm

	if _, err := c.CallTool(t.Context(), "vault", map[string]any{"action": "create"}); !errors.Is(err, left) {
		t.Fatalf("expected the wait's error, got %v", err)
	}
	if got := srv.sent(t); !equal(got, []string{""}) {
		t.Errorf("nothing is repeated, got %q", got)
	}
}

// Without a wait, or without an id to repeat under, the signal is the
// call's answer and nothing is sent again.
func TestCallTool_NoWaitOrNoIdRepeatsNothing(t *testing.T) {
	t.Run("no wait installed", func(t *testing.T) {
		srv := newScriptedServer(t, secretA)
		_, err := NewClient(srv.URL).CallTool(t.Context(), "vault", map[string]any{"action": "create"})
		if pending, _ := pendingConfirmation(err); pending == nil {
			t.Errorf("expected the signal, got %v", err)
		}
		if got := srv.sent(t); len(got) != 1 {
			t.Errorf("one request, got %d", len(got))
		}
	})

	t.Run("data stripped", func(t *testing.T) {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.WriteHeader(http.StatusBadRequest)
			io.WriteString(w, `{"jsonrpc":"2.0","id":1,"error":{"code":-33505,"message":"Confirmation required"}}`)
		}))
		defer srv.Close()

		waited := &confirmer{}
		c := NewClient(srv.URL)
		c.Confirm = waited.confirm
		_, err := c.CallTool(t.Context(), "vault", map[string]any{"action": "create"})

		var ce *ConsentError
		if !errors.As(err, &ce) || ce.Tag != "confirmation_required" {
			t.Errorf("expected the signal, got %v", err)
		}
		if len(waited.asked) != 0 {
			t.Errorf("no id to repeat under, yet the wait was asked %q", waited.asked)
		}
	})
}

// Only a repeat names a confirmation: discovery and listing carry none.
func TestWithMeta_CarriesAConfirmationIdOnlyWhenGiven(t *testing.T) {
	meta := withMeta(map[string]any{}, "", "")["_meta"].(map[string]any)
	if _, ok := meta[ConfirmationIDKey]; ok {
		t.Errorf("a request with no confirmation carries the key: %v", meta)
	}

	meta = withMeta(map[string]any{}, "", secretA)["_meta"].(map[string]any)
	if meta[ConfirmationIDKey] != secretA {
		t.Errorf("a repeat carries its id under %s: %v", ConfirmationIDKey, meta)
	}
	if meta["io.modelcontextprotocol/protocolVersion"] != protocolVersion {
		t.Errorf("a repeat still declares its version: %v", meta)
	}
}
