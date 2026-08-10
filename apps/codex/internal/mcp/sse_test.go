package mcp

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestOpenStream_ReceivesEvents(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "GET" {
			t.Errorf("expected GET, got %s", r.Method)
		}
		if r.Header.Get("Accept") != "text/event-stream" {
			t.Errorf("expected Accept: text/event-stream, got %q", r.Header.Get("Accept"))
		}
		if r.Header.Get("Authorization") != "Bearer sess-123" {
			t.Errorf("expected Authorization: Bearer sess-123, got %q", r.Header.Get("Authorization"))
		}

		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(200)

		flusher := w.(http.Flusher)

		// Send priming event (empty data)
		fmt.Fprintf(w, "id: 1\ndata:\n\n")
		flusher.Flush()

		// Send a notification
		notif := map[string]any{
			"jsonrpc": "2.0",
			"method":  "notifications/tools/list_changed",
		}
		data, _ := json.Marshal(notif)
		fmt.Fprintf(w, "id: 2\nevent: message\ndata: %s\n\n", data)
		flusher.Flush()
	}))
	defer srv.Close()

	c := NewClient(srv.URL)
	c.SessionID = "sess-123"

	stream, err := c.OpenStream("")
	if err != nil {
		t.Fatalf("OpenStream failed: %v", err)
	}
	defer stream.Close()

	select {
	case event := <-stream.Events:
		if event.ID != "2" {
			t.Errorf("expected event ID '2', got %q", event.ID)
		}
		var msg map[string]any
		if err := json.Unmarshal(event.Data, &msg); err != nil {
			t.Fatalf("failed to parse event data: %v", err)
		}
		if msg["method"] != "notifications/tools/list_changed" {
			t.Errorf("expected method notifications/tools/list_changed, got %v", msg["method"])
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for event")
	}
}

func TestOpenStream_NoSession(t *testing.T) {
	c := NewClient("http://example.com")
	_, err := c.OpenStream("")
	if err != ErrSessionRequired {
		t.Errorf("expected ErrSessionRequired, got %v", err)
	}
}

func TestOpenStream_LastEventID(t *testing.T) {
	var receivedLastEventID string

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		receivedLastEventID = r.Header.Get("Last-Event-ID")
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(200)
		// Close immediately
	}))
	defer srv.Close()

	c := NewClient(srv.URL)
	c.SessionID = "sess-123"

	stream, err := c.OpenStream("evt-42")
	if err != nil {
		t.Fatalf("OpenStream failed: %v", err)
	}
	defer stream.Close()

	if receivedLastEventID != "evt-42" {
		t.Errorf("expected Last-Event-ID 'evt-42', got %q", receivedLastEventID)
	}
}

func TestOpenStream_SessionExpired(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotFound)
	}))
	defer srv.Close()

	c := NewClient(srv.URL)
	c.SessionID = "stale-session"

	_, err := c.OpenStream("")
	if err != ErrSessionExpired {
		t.Errorf("expected ErrSessionExpired, got %v", err)
	}
}

func TestOpenStream_MethodNotAllowed(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusMethodNotAllowed)
	}))
	defer srv.Close()

	c := NewClient(srv.URL)
	c.SessionID = "sess-123"

	_, err := c.OpenStream("")
	if err == nil {
		t.Fatal("expected error for 405")
	}
}

func TestOpenStream_RetryField(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(200)

		flusher := w.(http.Flusher)

		// Send retry field
		fmt.Fprintf(w, "retry: 3000\n\n")
		flusher.Flush()

		// Send a real event so the test can synchronize
		notif := map[string]any{
			"jsonrpc": "2.0",
			"method":  "notifications/tools/list_changed",
		}
		data, _ := json.Marshal(notif)
		fmt.Fprintf(w, "id: 1\nevent: message\ndata: %s\n\n", data)
		flusher.Flush()
	}))
	defer srv.Close()

	c := NewClient(srv.URL)
	c.SessionID = "sess-123"

	stream, err := c.OpenStream("")
	if err != nil {
		t.Fatalf("OpenStream failed: %v", err)
	}
	defer stream.Close()

	// Wait for the event to ensure retry was processed
	select {
	case <-stream.Events:
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for event")
	}

	got := stream.RetryInterval(5 * time.Second)
	if got != 3*time.Second {
		t.Errorf("expected retry interval 3s, got %v", got)
	}
}

func TestOpenStream_RetryDefault(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(200)
		// Close immediately, no retry field sent
	}))
	defer srv.Close()

	c := NewClient(srv.URL)
	c.SessionID = "sess-123"

	stream, err := c.OpenStream("")
	if err != nil {
		t.Fatalf("OpenStream failed: %v", err)
	}
	defer stream.Close()

	got := stream.RetryInterval(5 * time.Second)
	if got != 5*time.Second {
		t.Errorf("expected default interval 5s, got %v", got)
	}
}

func TestCallTool_StructuredContent(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		resp := JSONRPCResponse{
			JSONRPC: "2.0",
			ID:      1,
			Result: map[string]any{
				"content": []map[string]any{
					{"type": "text", "text": `{"temperature":22.5,"conditions":"Sunny"}`},
				},
				"structuredContent": map[string]any{
					"temperature": 22.5,
					"conditions":  "Sunny",
				},
			},
		}
		json.NewEncoder(w).Encode(resp)
	}))
	defer srv.Close()

	c := NewClient(srv.URL)
	result, err := c.CallTool("weather", nil)
	if err != nil {
		t.Fatalf("CallTool failed: %v", err)
	}
	if result["temperature"] != 22.5 {
		t.Errorf("expected temperature 22.5, got %v", result["temperature"])
	}
	if result["conditions"] != "Sunny" {
		t.Errorf("expected conditions 'Sunny', got %v", result["conditions"])
	}
}
