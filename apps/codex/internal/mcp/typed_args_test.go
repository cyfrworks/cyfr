// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package mcp

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/cyfr/codex/internal/ops"
)

func TestCallToolSerializesTypedArguments(t *testing.T) {
	requests := make(chan json.RawMessage, 1)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var request struct {
			Params struct {
				Arguments json.RawMessage `json:"arguments"`
			} `json:"params"`
		}
		if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
			t.Error(err)
			return
		}
		requests <- request.Params.Arguments
		json.NewEncoder(w).Encode(JSONRPCResponse{JSONRPC: "2.0", ID: 1, Result: map[string]any{}})
	}))
	defer server.Close()
	_, err := NewClient(server.URL).CallTool(t.Context(), ops.Retention,
		ops.RetentionSetArgs{Settings: ops.RetentionSetArgsSettings{Executions: ops.Value(0)}})
	if err != nil {
		t.Fatal(err)
	}
	if request := <-requests; string(request) != `{"action":"set","settings":{"executions":0}}` {
		t.Fatalf("unexpected arguments: %s", request)
	}
}

func TestCallToolRefusesNonObjectArgumentsBeforeTransport(t *testing.T) {
	for _, args := range []any{false, 0, "invalid", []string{}} {
		_, err := NewClient("http://unused.invalid").CallTool(t.Context(), "test", args)
		if err == nil || err.Error() != "tool arguments must be a JSON object" {
			t.Fatalf("got %v for %T", err, args)
		}
	}
}
