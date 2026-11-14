// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
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

// A rotation says until when the old secret keeps working, the time the
// answer carries and the span from now to it, and how to end it now; an
// answer that names no such time claims none.
func TestRenderWebhookRotated(t *testing.T) {
	saved := webhookNow
	t.Cleanup(func() { webhookNow = saved })
	webhookNow = func() time.Time { return time.Date(2026, 11, 14, 6, 0, 0, 0, time.UTC) }
	result := map[string]any{
		"name":                "github-push",
		"url":                 "https://cyfr.example.com/hooks/wh_abc",
		"secret":              "whsec_newvalue",
		"previous_expires_at": "2026-11-15T06:00:00.123456Z",
	}

	out := captureStdout(t, func() { renderWebhookRotated(result) })

	head := "Webhook 'github-push' rotated.\n\n" +
		"  URL:    https://cyfr.example.com/hooks/wh_abc\n" +
		"\n  New secret: whsec_newvalue\n\n" +
		"  Copy this secret now. It will not be shown again.\n"
	want := head + "  The old secret keeps working until 2026-11-15 06:00:00 UTC, 24 hours from now. To end it now, revoke the webhook: cyfr webhook revoke github-push\n"
	if out != want {
		t.Errorf("rotate printed:\n%s\nwant:\n%s", out, want)
	}

	delete(result, "previous_expires_at")
	if out := captureStdout(t, func() { renderWebhookRotated(result) }); out != head {
		t.Errorf("rotate with no end time printed:\n%s\nwant:\n%s", out, head)
	}
}

// A span reads to the nearest minute, in hours and minutes.
func TestHoursAndMinutes(t *testing.T) {
	for d, want := range map[time.Duration]string{
		24*time.Hour + 20*time.Second: "24 hours",
		time.Hour:                     "1 hour",
		23*time.Hour + 59*time.Minute: "23 hours 59 minutes",
		61 * time.Minute:              "1 hour 1 minute",
		90 * time.Second:              "2 minutes",
		-time.Minute:                  "0 minutes",
	} {
		if got := hoursAndMinutes(d); got != want {
			t.Errorf("%v reads %q, want %q", d, got, want)
		}
	}
}

// The help says the old secret keeps working for a while after a rotation,
// that the answer says until when, and that revoking ends it now; and that
// a webhook answers before its run ends.
func TestWebhookHelpSaysWhenTheOldSecretEnds(t *testing.T) {
	for _, c := range []struct{ got, want string }{
		{webhookRotateCmd.Long, "Generate a new HMAC secret. The old secret keeps working for a while after a rotation, so the sender's configuration can move to the new one; the answer says until when. 'cyfr webhook revoke' ends the webhook now. Run without arguments for interactive selection."},
		{webhookRevokeCmd.Long, "Disable a webhook: its URL stops accepting POSTs now, whichever secret signs them, so revoking ends an old secret before the time a rotation leaves it is up. The audit trail is preserved. Run without arguments for interactive selection."},
		{webhookCmd.Long, "Manage inbound webhook receivers.\n\nEach webhook is a stable URL at /hooks/<slug> that verifies an HMAC-SHA256\nsignature against a stored secret, answers as soon as it accepts the\ndelivery, and then runs a target component: the answer does not say how\nthe run ends. The webhook can carry a static \"input_template\" (JSON object)\nthat gets merged into the invocation payload alongside the request envelope\n(headers, body, metadata) under the reserved key '_webhook'."},
	} {
		if c.got != c.want {
			t.Errorf("the help says:\n%s\nwant:\n%s", c.got, c.want)
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

// get prints every header the webhook reads: the signature's, and the
// timestamp and idempotency headers when set.
func TestRenderWebhookDetail(t *testing.T) {
	result := map[string]any{
		"name":                   "with-template",
		"url":                    "https://cyfr.example.com/hooks/wh_x",
		"target_ref":             "f:local.h",
		"signature_header":       "x-cyfr-signature",
		"timestamp_header":       "x-cyfr-timestamp",
		"idempotency_key_header": "x-github-delivery",
		"rate_limit":             "100/1m",
		"created_at":             "2026-05-04T10:00:00Z",
		"input_template": map[string]any{
			"channel": "alerts",
		},
	}

	out := captureStdout(t, func() { renderWebhookDetail(result) })

	want := "Webhook: with-template\n\n" +
		"  URL:    https://cyfr.example.com/hooks/wh_x\n" +
		"  Target:           f:local.h\n" +
		"  Signature header: x-cyfr-signature\n" +
		"  Timestamp header: x-cyfr-timestamp\n" +
		"  Idempotency key:  x-github-delivery\n" +
		"  Rate limit:       100/1m\n" +
		"  Created:          2026-05-04T10:00:00Z\n" +
		"  Input template:\n    {\n      \"channel\": \"alerts\"\n    }\n"
	if out != want {
		t.Errorf("get printed:\n%s\nwant:\n%s", out, want)
	}

	delete(result, "timestamp_header")
	delete(result, "idempotency_key_header")
	out = captureStdout(t, func() { renderWebhookDetail(result) })
	if strings.Contains(out, "Timestamp header") || strings.Contains(out, "Idempotency key") {
		t.Errorf("get printed headers the webhook does not read:\n%s", out)
	}
}
