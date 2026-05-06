package cmd

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestParseInputTemplate_Inline(t *testing.T) {
	got, err := parseInputTemplate(`{"channel":"alerts"}`, "")
	if err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	if v, _ := got["channel"].(string); v != "alerts" {
		t.Errorf("want channel=alerts, got %v", got)
	}
}

func TestParseInputTemplate_File(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "tmpl.json")
	if err := os.WriteFile(path, []byte(`{"v":1}`), 0644); err != nil {
		t.Fatalf("write: %v", err)
	}

	got, err := parseInputTemplate("", path)
	if err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	if v, _ := got["v"].(float64); v != 1 {
		t.Errorf("want v=1, got %v (%T)", got["v"], got["v"])
	}
}

func TestParseInputTemplate_BothMutuallyExclusive(t *testing.T) {
	_, err := parseInputTemplate(`{}`, "/tmp/x.json")
	if err == nil || !strings.Contains(err.Error(), "mutually exclusive") {
		t.Errorf("want mutually-exclusive error, got %v", err)
	}
}

func TestParseInputTemplate_RejectsArray(t *testing.T) {
	_, err := parseInputTemplate(`[1,2,3]`, "")
	if err == nil || !strings.Contains(err.Error(), "JSON object") {
		t.Errorf("want JSON-object error, got %v", err)
	}
}

func TestParseInputTemplate_RejectsScalar(t *testing.T) {
	_, err := parseInputTemplate(`"just a string"`, "")
	if err == nil {
		t.Errorf("want error for scalar, got nil")
	}
}

func TestParseInputTemplate_RejectsInvalidJSON(t *testing.T) {
	_, err := parseInputTemplate(`{not json`, "")
	if err == nil || !strings.Contains(err.Error(), "valid JSON") {
		t.Errorf("want JSON parse error, got %v", err)
	}
}

func TestParseInputTemplate_RejectsReservedKey(t *testing.T) {
	_, err := parseInputTemplate(`{"_webhook":{"x":1}}`, "")
	if err == nil || !strings.Contains(err.Error(), "_webhook") {
		t.Errorf("want reserved-key error, got %v", err)
	}
}

func TestParseInputTemplate_EmptyReturnsNil(t *testing.T) {
	got, err := parseInputTemplate("", "")
	if err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	if got != nil {
		t.Errorf("want nil for empty, got %v", got)
	}
}

func TestParseInputTemplate_EmptyObjectIsValid(t *testing.T) {
	got, err := parseInputTemplate(`{}`, "")
	if err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	if got == nil || len(got) != 0 {
		t.Errorf("want empty map, got %v", got)
	}
}

// The server constructs the URL using CYFR_PUBLIC_URL on the server side
// (which is the only side that knows the real public URL when the CLI is
// pointed at a remote install). The CLI just renders whatever url/slug the
// server returns.

func TestRenderWebhookCreated_WithServerURL(t *testing.T) {
	result := map[string]any{
		"name":       "github-push",
		"slug":       "wh_abc123",
		"url":        "https://cyfr.example.com/hooks/wh_abc123",
		"secret":     "whsec_supersecret",
		"target_ref": "f:local.handle-github",
	}

	out := captureStdout(t, func() { renderWebhookCreated(result) })

	expected := []string{
		"Webhook 'github-push' created.",
		"URL:    https://cyfr.example.com/hooks/wh_abc123",
		"Target: f:local.handle-github",
		"Secret: whsec_supersecret",
		"Copy this secret now",
	}
	for _, line := range expected {
		if !strings.Contains(out, line) {
			t.Errorf("expected %q in output, got:\n%s", line, out)
		}
	}
}

func TestRenderWebhookCreated_PathOnly_HintsCYFR_PUBLIC_URL(t *testing.T) {
	// Server returns path-only when CYFR_PUBLIC_URL is unset on the server.
	result := map[string]any{
		"name":   "no-url",
		"slug":   "wh_xyz",
		"url":    "/hooks/wh_xyz",
		"secret": "whsec_x",
	}

	out := captureStdout(t, func() { renderWebhookCreated(result) })

	if !strings.Contains(out, "Path:   /hooks/wh_xyz") {
		t.Errorf("expected path-only output, got:\n%s", out)
	}
	if !strings.Contains(out, "Set CYFR_PUBLIC_URL") {
		t.Errorf("expected hint about CYFR_PUBLIC_URL, got:\n%s", out)
	}
}

func TestRenderWebhookCreated_FallsBackToSlug_WhenNoURL(t *testing.T) {
	// Defensive: server didn't include url for some reason.
	result := map[string]any{
		"name":   "legacy",
		"slug":   "wh_legacy",
		"secret": "whsec_l",
	}

	out := captureStdout(t, func() { renderWebhookCreated(result) })

	if !strings.Contains(out, "/hooks/wh_legacy") {
		t.Errorf("expected fallback path, got:\n%s", out)
	}
}

func TestRenderWebhookRotated(t *testing.T) {
	result := map[string]any{
		"name":   "github-push",
		"url":    "https://cyfr.example.com/hooks/wh_abc",
		"secret": "whsec_newvalue",
	}

	out := captureStdout(t, func() { renderWebhookRotated(result) })

	expected := []string{
		"Webhook 'github-push' rotated.",
		"URL:    https://cyfr.example.com/hooks/wh_abc",
		"New secret: whsec_newvalue",
		"old secret is now invalid",
	}
	for _, line := range expected {
		if !strings.Contains(out, line) {
			t.Errorf("expected %q in output, got:\n%s", line, out)
		}
	}
}

func TestRenderWebhookList_Empty(t *testing.T) {
	result := map[string]any{
		"webhooks": []any{},
		"count":    float64(0),
	}

	out := captureStdout(t, func() { renderWebhookList(result) })

	if !strings.Contains(out, "No webhooks") {
		t.Errorf("expected empty-state message, got:\n%s", out)
	}
}

func TestRenderWebhookList_TableFormat(t *testing.T) {
	result := map[string]any{
		"webhooks": []any{
			map[string]any{
				"name":       "github-push",
				"target_ref": "f:local.gh",
				"url":        "https://cyfr.example.com/hooks/wh_a",
				"created_at": "2026-05-04T10:00:00Z",
			},
			map[string]any{
				"name":       "stripe",
				"target_ref": "f:local.stripe",
				"url":        "https://cyfr.example.com/hooks/wh_b",
				"created_at": "2026-05-04T11:00:00Z",
			},
		},
	}

	out := captureStdout(t, func() { renderWebhookList(result) })

	for _, want := range []string{"NAME", "TARGET", "URL", "github-push", "f:local.gh", "stripe"} {
		if !strings.Contains(out, want) {
			t.Errorf("expected %q in table output, got:\n%s", want, out)
		}
	}
}

func TestRenderWebhookDetail(t *testing.T) {
	result := map[string]any{
		"name":             "with-template",
		"url":              "https://cyfr.example.com/hooks/wh_x",
		"target_ref":       "f:local.h",
		"signature_header": "x-cyfr-signature",
		"rate_limit":       "100/1m",
		"created_at":       "2026-05-04T10:00:00Z",
		"input_template": map[string]any{
			"channel": "alerts",
		},
	}

	out := captureStdout(t, func() { renderWebhookDetail(result) })

	for _, want := range []string{
		"Webhook: with-template",
		"URL:    https://cyfr.example.com/hooks/wh_x",
		"Target:           f:local.h",
		"Signature header: x-cyfr-signature",
		"Rate limit:       100/1m",
		"Input template:",
		"channel",
		"alerts",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("expected %q in detail output, got:\n%s", want, out)
		}
	}
}
