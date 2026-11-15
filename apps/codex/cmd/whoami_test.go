// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bytes"
	"encoding/json"
	"io"
	"os"
	"reflect"
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
			"user_id":  "usr_01a1b22b-65db-757a-bd55-ca3e66da8560",
			"email":    "alice@example.com",
			"provider": "passkey",
		},
		"registry": map[string]any{
			"authenticated":      true,
			"personal_namespace": map[string]any{"slug": "alice"},
			"memberships":        []any{},
		},
	}

	out := captureStdout(t, func() { renderWhoami(composed, nil) })

	expectedLines := []string{
		"cyfr.run name: alice",
		"Provider: passkey",
		"Email: alice@example.com",
		"User ID: usr_01a1b22b-65db-757a-bd55-ca3e66da8560",
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

	if !strings.Contains(out, "cyfr.run name: alice") {
		t.Errorf("expected slug-promoted top line, got:\n%s", out)
	}
	if !strings.Contains(out, "Memberships: stripe.com (admin), acme.com (member)") {
		t.Errorf("expected memberships line, got:\n%s", out)
	}
}

func TestRenderWhoami_Unclaimed(t *testing.T) {
	composed := map[string]any{
		"session": map[string]any{
			"user_id":  "usr_01a1b22b-65db-757a-bd55-ca3e66da8561",
			"email":    "bob@example.com",
			"provider": "passkey",
		},
		"registry": map[string]any{
			"authenticated":      true,
			"personal_namespace": nil,
			"memberships":        []any{},
		},
	}

	out := captureStdout(t, func() { renderWhoami(composed, nil) })

	if !strings.Contains(out, "cyfr.run name: (no personal namespace claimed)") {
		t.Errorf("expected unclaimed status on the cyfr.run name line, got:\n%s", out)
	}
	if !strings.Contains(out, "Your name is not finished yet: finish it in Settings.") {
		t.Errorf("expected the unfinished-name hint on stderr, got:\n%s", out)
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

	if !strings.Contains(out, "cyfr.run name: (no cyfr.run push tokens)") {
		t.Errorf("expected registry-unauthenticated status, got:\n%s", out)
	}
	if !strings.Contains(out, "Finish your name in Settings") || !strings.Contains(out, "Registry page") {
		t.Errorf("expected the name and sync hint on stderr, got:\n%s", out)
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

	if !strings.Contains(out, "cyfr.run name: (registry.cyfr.run unreachable)") {
		t.Errorf("expected registry-unreachable status, got:\n%s", out)
	}
}

func TestRenderWhoami_SignedOut(t *testing.T) {
	composed := map[string]any{
		"session": map[string]any{},
	}

	out := captureStdout(t, func() { renderWhoami(composed, nil) })

	if !strings.Contains(out, "No API key.") {
		t.Errorf("expected signed-out render, got:\n%s", out)
	}
}

func TestPrettyProvider(t *testing.T) {
	cases := map[string]string{
		"passkey":       "passkey",
		"device":        "device",
		"":              "unknown",
		"unknown-thing": "unknown-thing",
	}
	for in, want := range cases {
		if got := prettyProvider(in); got != want {
			t.Errorf("prettyProvider(%q) = %q, want %q", in, got, want)
		}
	}
}

// With a key, whoami names the key, its person's name and role, and the
// address it called, before the cyfr.run name; it sends the two reads and
// nothing else.
func TestWhoami_WithAKeyNamesTheKeyItsPersonAndTheAddress(t *testing.T) {
	srv := newCLIServer(t, "",
		`{"user_id":"usr_0a","email":"alice@example.com","provider":"api_key","athanor_id":"ath_0a","platform_admin":false,"session_expires_at":null,"key_name":"ci-runner","name":"Alice","role":"person"}`,
		`{"authenticated":true,"personal_namespace":{"slug":"alice"},"memberships":[]}`,
	)

	out, err := runCLI(t, srv, "whoami")
	if err != nil {
		t.Fatalf("whoami: %v\n%s", err, out)
	}

	want := "Key: ci-runner\n" +
		"Name: Alice\n" +
		"Role: person\n" +
		"Address: " + srv.URL + "\n" +
		"cyfr.run name: alice\n" +
		"Provider: api_key\n" +
		"Email: alice@example.com\n" +
		"Athanor: ath_0a\n" +
		"User ID: usr_0a\n"
	if out != want {
		t.Fatalf("whoami printed:\n%s\nwant:\n%s", out, want)
	}
	if srv.count() != 2 {
		t.Fatalf("whoami sent %d requests, want the two reads", srv.count())
	}
	if name, args := srv.call(0); name != "session" || args["action"] != "whoami" {
		t.Fatalf("first request %s %v, want session.whoami", name, args)
	}
}

// --json carries the address beside the server's answers.
func TestWhoami_JSONCarriesTheAddress(t *testing.T) {
	srv := newCLIServer(t, "",
		`{"user_id":"usr_0a","key_name":"ci-runner","name":"Alice","role":"administrator"}`,
		`{"authenticated":true,"personal_namespace":null,"memberships":[]}`,
	)

	out, err := runCLI(t, srv, "whoami", "--json")
	if err != nil {
		t.Fatalf("whoami --json: %v\n%s", err, out)
	}
	var got map[string]any
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("whoami --json printed no JSON: %v\n%s", err, out)
	}
	want := map[string]any{
		"address":  srv.URL,
		"session":  map[string]any{"user_id": "usr_0a", "key_name": "ci-runner", "name": "Alice", "role": "administrator"},
		"registry": map[string]any{"authenticated": true, "personal_namespace": nil, "memberships": []any{}},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("whoami --json = %#v, want %#v", got, want)
	}
}
