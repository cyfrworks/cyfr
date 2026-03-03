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

func TestInitialize_CapturesSessionID(t *testing.T) {
	var requestCount int
	var notificationBody []byte

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requestCount++
		body, _ := io.ReadAll(r.Body)

		if requestCount == 1 {
			// First request: initialize
			w.Header().Set("Mcp-Session-Id", "sess-abc123")
			resp := JSONRPCResponse{
				JSONRPC: "2.0",
				ID:      1,
				Result: map[string]any{
					"protocolVersion": "2025-11-25",
					"capabilities":    map[string]any{},
					"serverInfo":      map[string]any{"name": "cyfr", "version": "0.1.0"},
				},
			}
			json.NewEncoder(w).Encode(resp)
		} else {
			// Second request: notifications/initialized
			notificationBody = body
			w.WriteHeader(http.StatusAccepted)
		}
	}))
	defer srv.Close()

	c := NewClient(srv.URL)
	if err := c.Initialize(); err != nil {
		t.Fatalf("Initialize failed: %v", err)
	}
	if c.SessionID != "sess-abc123" {
		t.Errorf("expected SessionID 'sess-abc123', got %q", c.SessionID)
	}

	// Verify 2 requests were sent (initialize + notification)
	if requestCount != 2 {
		t.Fatalf("expected 2 requests (initialize + notification), got %d", requestCount)
	}

	// Verify notification has no "id" field
	var notif map[string]any
	if err := json.Unmarshal(notificationBody, &notif); err != nil {
		t.Fatalf("failed to parse notification body: %v", err)
	}
	if _, hasID := notif["id"]; hasID {
		t.Error("notification must not have 'id' field")
	}
	if notif["method"] != "notifications/initialized" {
		t.Errorf("expected method 'notifications/initialized', got %v", notif["method"])
	}
	if notif["jsonrpc"] != "2.0" {
		t.Errorf("expected jsonrpc '2.0', got %v", notif["jsonrpc"])
	}
}

func TestInitialize_RejectsUnsupportedProtocol(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Mcp-Session-Id", "sess-xyz")
		resp := JSONRPCResponse{
			JSONRPC: "2.0",
			ID:      1,
			Result: map[string]any{
				"protocolVersion": "2099-01-01",
				"capabilities":    map[string]any{},
				"serverInfo":      map[string]any{"name": "future-server", "version": "9.9.9"},
			},
		}
		json.NewEncoder(w).Encode(resp)
	}))
	defer srv.Close()

	c := NewClient(srv.URL)
	err := c.Initialize()
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
	result, err := c.CallTool("test-tool", nil)
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
	result, err := c.CallTool("test-tool", nil)
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
	_, err := c.CallTool("test-tool", nil)
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
	_, err := c.CallTool("test-tool", nil)
	if err == nil {
		t.Fatal("expected error for RPC error response")
	}
	if !strings.Contains(err.Error(), "invalid request") {
		t.Errorf("expected error containing 'invalid request', got %q", err.Error())
	}
}

func TestCallTool_SessionExpired(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotFound)
		resp := JSONRPCResponse{
			JSONRPC: "2.0",
			ID:      1,
			Error:   &JSONRPCError{Code: -33302, Message: "session not found"},
		}
		json.NewEncoder(w).Encode(resp)
	}))
	defer srv.Close()

	c := NewClient(srv.URL)
	c.SessionID = "stale-session"
	_, err := c.CallTool("test-tool", nil)
	if err == nil {
		t.Fatal("expected error for expired session")
	}
	if !errors.Is(err, ErrSessionExpired) {
		t.Errorf("expected ErrSessionExpired, got %v", err)
	}
}

func TestCallTool_SessionExpired_Bare404(t *testing.T) {
	// MCP spec: server MAY return bare HTTP 404 (no JSON-RPC body) when session expires.
	// Client MUST treat this as session expired and auto-recover.
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotFound)
		w.Write([]byte("Not Found"))
	}))
	defer srv.Close()

	c := NewClient(srv.URL)
	c.SessionID = "stale-session"
	_, err := c.CallTool("test-tool", nil)
	if err == nil {
		t.Fatal("expected error for bare 404")
	}
	if !errors.Is(err, ErrSessionExpired) {
		t.Errorf("expected ErrSessionExpired, got %v", err)
	}
}

func TestClose_SendsDelete(t *testing.T) {
	var deleteReceived bool
	var deleteSessionID string

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == "DELETE" {
			deleteReceived = true
			deleteSessionID = r.Header.Get("MCP-Session-Id")
			w.WriteHeader(http.StatusOK)
			return
		}
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	c := NewClient(srv.URL)
	c.SessionID = "sess-to-close"

	if err := c.Close(); err != nil {
		t.Fatalf("Close failed: %v", err)
	}
	if !deleteReceived {
		t.Error("expected DELETE request to be sent")
	}
	if deleteSessionID != "sess-to-close" {
		t.Errorf("expected session ID 'sess-to-close', got %q", deleteSessionID)
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
	_, err := c.CallTool("test-tool", nil)
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
	tools, err := c.ListTools()
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
	_, err := c.CallTool("test-tool", nil)
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

func TestRequestHeaders(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Verify headers
		if ct := r.Header.Get("Content-Type"); ct != "application/json" {
			t.Errorf("expected Content-Type 'application/json', got %q", ct)
		}
		if accept := r.Header.Get("Accept"); accept != "application/json, text/event-stream" {
			t.Errorf("expected Accept 'application/json, text/event-stream', got %q", accept)
		}
		if pv := r.Header.Get("MCP-Protocol-Version"); pv != "2025-11-25" {
			t.Errorf("expected MCP-Protocol-Version '2025-11-25', got %q", pv)
		}
		if sid := r.Header.Get("MCP-Session-Id"); sid != "my-session" {
			t.Errorf("expected MCP-Session-Id 'my-session', got %q", sid)
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
	_, _ = c.ListTools()
}
