// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/cyfr/codex/internal/ops"
)

// A name is passed to door.allow and door.deny as typed, in the value the
// operation reads its kind from.
func TestAdminSendsANameAsTheValue(t *testing.T) {
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
			t.Errorf("%s sent %v, want the action and the name as its value", action, sent)
		}
	}
}

func TestAdminHelpNamesAName(t *testing.T) {
	for _, cmd := range []struct{ use, short string }{
		{adminAllowCmd.Use, adminAllowCmd.Short},
		{adminDenyCmd.Use, adminDenyCmd.Short},
	} {
		if !strings.Contains(cmd.use, "@name") {
			t.Errorf("usage %q does not name a name", cmd.use)
		}
		if !strings.Contains(cmd.short, "name (@name)") {
			t.Errorf("help %q does not name a name", cmd.short)
		}
	}
	if !strings.Contains(adminCmd.Long, "name (@name)") {
		t.Errorf("admin help does not name a name: %q", adminCmd.Long)
	}
	help := strings.ToLower(adminCmd.Long + adminAllowCmd.Use + adminAllowCmd.Short + adminDenyCmd.Use + adminDenyCmd.Short)
	for _, word := range []string{"handle", "registry"} {
		if strings.Contains(help, word) {
			t.Errorf("admin help says %q", word)
		}
	}
}

// An entry made from a name shows the name beside its identifier; one made
// otherwise shows its value alone.
func TestAdminShowsAnEntrysName(t *testing.T) {
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
