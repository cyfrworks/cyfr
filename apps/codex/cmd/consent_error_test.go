// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/cyfr/codex/internal/mcp"
)

// confirmationServer answers every call as the server answers a sensitive
// change that waits for a fresh confirmation: -33505 at HTTP 400, the
// pending confirmation in error.data, or no data when a proxy stripped it.
func confirmationServer(withData bool) *httptest.Server {
	body := `{"jsonrpc":"2.0","id":1,"error":{"code":-33505,` +
		`"message":"Confirmation required: vault/create needs a fresh confirmation — confirm it in Prism (confirmation confirmation-7f3a)"`
	if withData {
		body += `,"data":{"tag":"confirmation_required","payload":` +
			`{"id":"confirmation-7f3a","operation":"vault/create","expires_at":"2026-09-29T12:05:00Z"}}`
	}
	body += `}}`

	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		io.WriteString(w, body)
	}))
}

// A command meeting -33505 ends in an error that names the confirmation,
// says nothing was changed and sends the person to Prism — never success,
// and never the generic failure.
func TestConfirmationRequired_RendersTheIdAndIsNeverSuccess(t *testing.T) {
	srv := confirmationServer(true)
	defer srv.Close()

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
	for _, want := range []string{"confirmation-7f3a", "nothing was changed", "Prism", "vault/create"} {
		if !strings.Contains(text, want) {
			t.Errorf("rendered output lacks %q:\n%s", want, text)
		}
	}
	if strings.HasPrefix(text, "Create failed") || strings.HasPrefix(text, "Failed") {
		t.Errorf("fell through to the generic failure:\n%s", text)
	}
}

// With error.data stripped the code still names the tag: the rendering
// still says nothing was changed and sends the person to Prism.
func TestConfirmationRequired_WithoutDataStillSendsThePersonToPrism(t *testing.T) {
	srv := confirmationServer(false)
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
	for _, want := range []string{"Confirmation required", "nothing was changed", "Prism"} {
		if !strings.Contains(text, want) {
			t.Errorf("rendered output lacks %q:\n%s", want, text)
		}
	}
}

// The formatter alone: the id, the operation and the expiry the payload
// names, as the wire carries them.
func TestFormatConsentError_ConfirmationRequired(t *testing.T) {
	text := formatConsentError("confirmation_required", map[string]any{
		"id":         "confirmation-7f3a",
		"operation":  "vault/create",
		"expires_at": "2026-09-29T12:05:00Z",
	})

	want := "Confirmation required: vault/create needs a fresh confirmation (confirmation confirmation-7f3a); nothing was changed.\n" +
		"  Confirm and complete it in Prism before 2026-09-29T12:05:00Z."
	if text != want {
		t.Errorf("got:\n%s\nwant:\n%s", text, want)
	}
}
