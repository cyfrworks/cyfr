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

// An argument is read as the handle, identifier or user id it is spelled
// as: a leading @ makes a handle, whose spelling the server reads; only
// the identifier grammar Prima.Identity holds makes an identifier; and an
// email is no form at all: it is sent as the user id it is not.
func TestMemberKeyReadsTheThreeForms(t *testing.T) {
	for _, identifier := range vectorIdentifiers(t) {
		if got := memberKey(identifier); got != "identifier" {
			t.Errorf("memberKey(%q) = %q, want identifier", identifier, got)
		}
	}

	hex := strings.Repeat("ab", 32)
	cases := map[string]string{
		"@alice":                      "handle",
		"@Not A Handle":               "handle",
		"@":                           "handle",
		"alice":                       "user_id",
		"someone@example.com":         "user_id",
		"usr_01a0f6f8-1629-79c3-9217": "user_id",
		"per_" + strings.ToUpper(hex): "user_id",
		"per_" + hex[:62]:             "user_id",
		"per_" + hex + "0":            "user_id",
		" per_" + hex:                 "user_id",
		"per_x":                       "user_id",
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
		identifier:                    "identifier",
		"usr_01a0f6f8-1629-79c3-9217": "user_id",
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

	// A handle is sent as typed, in the one field add takes it in.
	raw, err := json.Marshal(memberAddArgs(athanor, "@alice"))
	if err != nil {
		t.Fatal(err)
	}
	var sent map[string]any
	if err := json.Unmarshal(raw, &sent); err != nil {
		t.Fatal(err)
	}
	if len(sent) != 3 || sent["action"] != "add" || sent["athanor"] != "team" || sent["handle"] != "@alice" {
		t.Errorf("add @alice sent %v, want action, athanor and handle alone", sent)
	}

	// No athanor named: the one in focus, so the field is absent.
	raw, err = json.Marshal(memberAddArgs(ops.Field[string]{}, identifier))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(raw), "athanor") {
		t.Errorf("an unnamed athanor was sent: %s", raw)
	}
}

func TestMemberHelpNamesTheForms(t *testing.T) {
	if !strings.Contains(memberAddCmd.Use, "<user_id|identifier|@handle>") {
		t.Errorf("usage %q does not name the three forms", memberAddCmd.Use)
	}
	if !strings.Contains(memberAddCmd.Short, "handle (@name)") {
		t.Errorf("help %q does not name a handle", memberAddCmd.Short)
	}
	if !strings.Contains(memberRemoveCmd.Use, "<user_id|identifier>") {
		t.Errorf("usage %q does not name the two forms", memberRemoveCmd.Use)
	}
	for _, cmd := range []struct{ use, short string }{
		{memberAddCmd.Use, memberAddCmd.Short},
		{memberRemoveCmd.Use, memberRemoveCmd.Short},
	} {
		for _, form := range []string{"user id", "person identifier"} {
			if !strings.Contains(cmd.short, form) {
				t.Errorf("help %q does not name %s", cmd.short, form)
			}
		}
		if strings.Contains(strings.ToLower(cmd.use+cmd.short), "email") {
			t.Errorf("help %q %q still names an email", cmd.use, cmd.short)
		}
	}
	for _, form := range []string{"user id", "person identifier", "handle (@name)"} {
		if !strings.Contains(memberCmd.Long, form) {
			t.Errorf("member help does not name %s", form)
		}
	}
	if strings.Contains(strings.ToLower(memberCmd.Long), "email") {
		t.Errorf("member help still names an email: %q", memberCmd.Long)
	}
}

// A removal names someone this server holds a row for: a handle is refused
// before any call is made.
func TestMemberRemoveRefusesAHandle(t *testing.T) {
	err := memberRemoveCmd.RunE(memberRemoveCmd, []string{"@alice"})
	if err == nil || !strings.Contains(err.Error(), "user id or person identifier") {
		t.Errorf("remove @alice answered %v, want a refusal naming the two forms", err)
	}
}
