// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/cyfr/codex/internal/mcp"
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

// A cancelled context must end the poll loop promptly. Ctrl-C used to be
// treated as one more transient network error, so the loop spun until the
// device-flow deadline (~15 minutes).
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
			50*time.Millisecond, time.Now().Add(30*time.Second), 30)
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
		10*time.Millisecond, time.Now().Add(5*time.Second), 5)
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
		10*time.Millisecond, time.Now().Add(5*time.Second), 5)
	if err == nil || !strings.Contains(err.Error(), "Authorization denied") {
		t.Fatalf("want denial error, got %v", err)
	}
}

func TestPollDeviceAuth_DeadlineTimesOut(t *testing.T) {
	// Deadline already passed: the loop must not poll at all.
	client := mcp.NewClient("http://127.0.0.1:0")
	_, err := pollDeviceAuth(t.Context(), client, "github", "dev-code",
		10*time.Millisecond, time.Now().Add(-time.Second), 900)
	if err == nil || !strings.Contains(err.Error(), "Login timed out") {
		t.Fatalf("want timeout error, got %v", err)
	}
}
