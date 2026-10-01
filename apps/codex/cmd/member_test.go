// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/cyfr/codex/internal/ops"
)

// identityVectors is the part of tests/fixtures/identity.json, the vector
// file of Prima.Identity, that names people by their identifiers.
type identityVectors struct {
	Identifiers map[string]string `json:"identifiers"`
}

func vectorIdentifiers(t *testing.T) []string {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "tests", "fixtures", "identity.json"))
	if err != nil {
		t.Fatalf("read the vector file: %v", err)
	}
	var v identityVectors
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatal(err)
	}
	if len(v.Identifiers) == 0 {
		t.Fatal("the vector file names no identifier")
	}
	identifiers := make([]string, 0, len(v.Identifiers))
	for _, identifier := range v.Identifiers {
		identifiers = append(identifiers, identifier)
	}
	return identifiers
}

// An argument is read as the identifier, email or user id it is spelled
// as; only the identifier grammar Prima.Identity holds makes an identifier.
func TestMemberKeyReadsTheThreeForms(t *testing.T) {
	for _, identifier := range vectorIdentifiers(t) {
		if got := memberKey(identifier); got != "identifier" {
			t.Errorf("memberKey(%q) = %q, want identifier", identifier, got)
		}
	}

	hex := strings.Repeat("ab", 32)
	cases := map[string]string{
		"someone@example.com":          "email",
		"github|https://github.com|42": "user_id",
		"usr_01a0f6f8-1629-79c3-9217":  "user_id",
		"per_" + strings.ToUpper(hex):  "user_id",
		"per_" + hex[:62]:              "user_id",
		"per_" + hex + "0":             "user_id",
		" per_" + hex:                  "user_id",
		"per_x":                        "user_id",
	}
	for target, want := range cases {
		if got := memberKey(target); got != want {
			t.Errorf("memberKey(%q) = %q, want %q", target, got, want)
		}
	}
}

// The payloads add and remove send name the person by exactly the one
// field the argument's form fills, beside the athanor when one is named.
func TestMemberArgsSendTheOneFieldTheFormFills(t *testing.T) {
	identifier := vectorIdentifiers(t)[0]
	athanor := ops.Value("team")

	for target, field := range map[string]string{
		identifier:                     "identifier",
		"someone@example.com":          "email",
		"github|https://github.com|42": "user_id",
	} {
		for action, payload := range map[string]any{
			"add":    memberAddArgs(athanor, target),
			"remove": memberRemoveArgs(athanor, target),
		} {
			raw, err := json.Marshal(payload)
			if err != nil {
				t.Fatal(err)
			}
			var sent map[string]any
			if err := json.Unmarshal(raw, &sent); err != nil {
				t.Fatal(err)
			}
			want := map[string]any{"action": action, "athanor": "team", field: target}
			if len(sent) != len(want) {
				t.Errorf("%s %q sent %v, want %v", action, target, sent, want)
				continue
			}
			for key, value := range want {
				if sent[key] != value {
					t.Errorf("%s %q sent %s = %v, want %v", action, target, key, sent[key], value)
				}
			}
		}
	}

	// No athanor named: the one in focus, so the field is absent.
	raw, err := json.Marshal(memberAddArgs(ops.Field[string]{}, identifier))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(raw), "athanor") {
		t.Errorf("an unnamed athanor was sent: %s", raw)
	}
}

func TestMemberHelpNamesTheThreeForms(t *testing.T) {
	for _, cmd := range []struct{ use, short string }{
		{memberAddCmd.Use, memberAddCmd.Short},
		{memberRemoveCmd.Use, memberRemoveCmd.Short},
	} {
		if !strings.Contains(cmd.use, "<email|user_id|identifier>") {
			t.Errorf("usage %q does not name the three forms", cmd.use)
		}
		for _, form := range []string{"email", "user id", "person identifier"} {
			if !strings.Contains(cmd.short, form) {
				t.Errorf("help %q does not name %s", cmd.short, form)
			}
		}
	}
	for _, form := range []string{"email", "user id", "person identifier"} {
		if !strings.Contains(memberCmd.Long, form) {
			t.Errorf("member help does not name %s", form)
		}
	}
}
