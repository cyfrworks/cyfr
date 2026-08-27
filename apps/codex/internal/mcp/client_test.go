// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package mcp

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
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

// A 404 means the server does not implement the method — not that a session
// expired. There are no sessions, and reading it the old way told an
// authenticated user to log in again whenever they hit a missing method.
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
