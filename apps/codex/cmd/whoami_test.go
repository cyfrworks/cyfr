// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bytes"
	"io"
	"os"
	"strings"
	"testing"
)

// captureStdout redirects os.Stdout+os.Stderr for the duration of fn and
// returns their combined output. Simplest way to snapshot renderWhoami
// since it writes to fmt.Println (stdout) and fmt.Fprintln(os.Stderr, ...).
func captureStdout(t *testing.T, fn func()) string {
	t.Helper()

	origStdout := os.Stdout
	origStderr := os.Stderr

	rOut, wOut, _ := os.Pipe()
	rErr, wErr, _ := os.Pipe()

	os.Stdout = wOut
	os.Stderr = wErr

	fn()

	wOut.Close()
	wErr.Close()
	os.Stdout = origStdout
	os.Stderr = origStderr

	var outBuf, errBuf bytes.Buffer
	_, _ = io.Copy(&outBuf, rOut)
	_, _ = io.Copy(&errBuf, rErr)

	return outBuf.String() + errBuf.String()
}

func TestRenderWhoami_Claimed(t *testing.T) {
	composed := map[string]any{
		"session": map[string]any{
			"user_id":  "google|https://accounts.google.com|107518896565179043523",
			"email":    "alice@example.com",
			"provider": "google",
		},
		"registry": map[string]any{
			"authenticated":      true,
			"personal_namespace": map[string]any{"slug": "moonmoon"},
			"memberships":        []any{},
		},
	}

	out := captureStdout(t, func() { renderWhoami(composed, nil) })

	expectedLines := []string{
		"CYFR User: moonmoon",
		"Provider: Google",
		"Email: alice@example.com",
		"User ID: google|https://accounts.google.com|107518896565179043523",
	}
	for _, line := range expectedLines {
		if !strings.Contains(out, line) {
			t.Errorf("expected %q in output, got:\n%s", line, out)
		}
	}
}

func TestRenderWhoami_ClaimedWithMemberships(t *testing.T) {
	composed := map[string]any{
		"session": map[string]any{
			"user_id":  "github|https://github.com|111",
			"email":    "alice@example.com",
			"provider": "github",
		},
		"registry": map[string]any{
			"authenticated":      true,
			"personal_namespace": map[string]any{"slug": "alice"},
			"memberships": []any{
				map[string]any{"slug": "stripe.com", "role": "admin"},
				map[string]any{"slug": "acme.com", "role": "member"},
			},
		},
	}

	out := captureStdout(t, func() { renderWhoami(composed, nil) })

	if !strings.Contains(out, "CYFR User: alice") {
		t.Errorf("expected slug-promoted top line, got:\n%s", out)
	}
	if !strings.Contains(out, "Memberships: stripe.com (admin), acme.com (member)") {
		t.Errorf("expected memberships line, got:\n%s", out)
	}
}

func TestRenderWhoami_Unclaimed(t *testing.T) {
	composed := map[string]any{
		"session": map[string]any{
			"user_id":  "google|https://accounts.google.com|107",
			"email":    "bob@example.com",
			"provider": "google",
		},
		"registry": map[string]any{
			"authenticated":      true,
			"personal_namespace": nil,
			"memberships":        []any{},
		},
	}

	out := captureStdout(t, func() { renderWhoami(composed, nil) })

	if !strings.Contains(out, "CYFR User: (no personal namespace claimed)") {
		t.Errorf("expected unclaimed status on CYFR User line, got:\n%s", out)
	}
	if !strings.Contains(out, "Run `cyfr login` to claim your personal namespace.") {
		t.Errorf("expected claim-namespace hint on stderr, got:\n%s", out)
	}
}

func TestRenderWhoami_RegistryUnauthenticated(t *testing.T) {
	composed := map[string]any{
		"session": map[string]any{
			"user_id":  "github|https://github.com|999",
			"email":    "c@example.com",
			"provider": "github",
		},
		"registry": map[string]any{
			"authenticated": false,
		},
	}

	out := captureStdout(t, func() { renderWhoami(composed, nil) })

	if !strings.Contains(out, "CYFR User: (not logged in to cyfr.run)") {
		t.Errorf("expected registry-unauthenticated status, got:\n%s", out)
	}
}

func TestRenderWhoami_RegistryUnreachable(t *testing.T) {
	composed := map[string]any{
		"session": map[string]any{
			"user_id":  "github|https://github.com|999",
			"email":    "c@example.com",
			"provider": "github",
		},
		"registry_error": "connection refused",
	}

	out := captureStdout(t, func() { renderWhoami(composed, nil) })

	if !strings.Contains(out, "CYFR User: (registry.cyfr.run unreachable)") {
		t.Errorf("expected registry-unreachable status, got:\n%s", out)
	}
}

func TestRenderWhoami_SignedOut(t *testing.T) {
	composed := map[string]any{
		"session": map[string]any{},
	}

	out := captureStdout(t, func() { renderWhoami(composed, nil) })

	if !strings.Contains(out, "Not signed in.") {
		t.Errorf("expected signed-out render, got:\n%s", out)
	}
}

func TestPrettyProvider(t *testing.T) {
	cases := map[string]string{
		"github":        "GitHub",
		"google":        "Google",
		"oidcc":         "OIDC",
		"":              "unknown",
		"unknown-thing": "unknown-thing",
	}
	for in, want := range cases {
		if got := prettyProvider(in); got != want {
			t.Errorf("prettyProvider(%q) = %q, want %q", in, got, want)
		}
	}
}
