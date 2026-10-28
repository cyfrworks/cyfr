// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/cyfr/codex/internal/ops"
)

// A handle is passed to door.allow and door.deny as typed, in the value the
// operation reads its kind from.
func TestAdminSendsAHandleAsTheValue(t *testing.T) {
	for action, payload := range map[string]any{
		"allow": ops.DoorAllowArgs{Value: "@alice"},
		"deny":  ops.DoorDenyArgs{Value: "@alice"},
	} {
		raw, err := json.Marshal(payload)
		if err != nil {
			t.Fatal(err)
		}
		var sent map[string]any
		if err := json.Unmarshal(raw, &sent); err != nil {
			t.Fatal(err)
		}
		if len(sent) != 2 || sent["action"] != action || sent["value"] != "@alice" {
			t.Errorf("%s sent %v, want the action and the handle as its value", action, sent)
		}
	}
}

func TestAdminHelpNamesAHandle(t *testing.T) {
	for _, cmd := range []struct{ use, short string }{
		{adminAllowCmd.Use, adminAllowCmd.Short},
		{adminDenyCmd.Use, adminDenyCmd.Short},
	} {
		if !strings.Contains(cmd.use, "@handle") {
			t.Errorf("usage %q does not name a handle", cmd.use)
		}
		if !strings.Contains(cmd.short, "handle (@name)") {
			t.Errorf("help %q does not name a handle", cmd.short)
		}
	}
	if !strings.Contains(adminCmd.Long, "handle (@name)") {
		t.Errorf("admin help does not name a handle: %q", adminCmd.Long)
	}
}

// An entry made from a handle shows the handle beside its identifier; one
// made otherwise shows its value alone.
func TestAdminShowsAnEntrysHandle(t *testing.T) {
	identifier := "per_" + strings.Repeat("ab", 32)
	cases := []struct {
		entry map[string]any
		want  string
	}{
		{map[string]any{"value": identifier, "label": "alice"}, identifier + " (@alice)"},
		{map[string]any{"value": identifier}, identifier},
		{map[string]any{"value": "*"}, "*"},
	}
	for _, c := range cases {
		if got := entryShown(c.entry); got != c.want {
			t.Errorf("entryShown(%v) = %q, want %q", c.entry, got, c.want)
		}
	}
}
