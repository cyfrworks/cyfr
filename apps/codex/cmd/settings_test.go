// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/cyfr/codex/internal/ops"
	"github.com/spf13/cobra"
)

func revisionCommand() *cobra.Command {
	c := &cobra.Command{Use: "x"}
	c.Flags().Int("revision", 0, "")
	return c
}

func TestSettingsRevision_AbsentUnlessGiven(t *testing.T) {
	c := revisionCommand()
	revision, err := settingsRevision(c)
	if err != nil {
		t.Fatal(err)
	}
	encoded, _ := json.Marshal(ops.SettingsSetArgs{Key: "log_level", Value: "debug", Revision: revision})
	if want := `{"action":"set","key":"log_level","value":"debug"}`; string(encoded) != want {
		t.Errorf("want %s, got %s", want, encoded)
	}

	if err := c.Flags().Set("revision", "0"); err != nil {
		t.Fatal(err)
	}
	revision, err = settingsRevision(c)
	if err != nil {
		t.Fatal(err)
	}
	encoded, _ = json.Marshal(ops.SettingsResetArgs{Key: "log_level", Revision: revision})
	if want := `{"action":"reset","key":"log_level","revision":0}`; string(encoded) != want {
		t.Errorf("an explicit zero is a revision: want %s, got %s", want, encoded)
	}
}

func TestSettingsRevision_RefusesANegativeRevision(t *testing.T) {
	c := revisionCommand()
	if err := c.Flags().Set("revision", "-1"); err != nil {
		t.Fatal(err)
	}
	if _, err := settingsRevision(c); err == nil {
		t.Error("want an error for a negative revision, got nil")
	}
}

func TestSettingsLines_ShowSourcePendingAndEachMember(t *testing.T) {
	var result map[string]any
	payload := `{
	  "revision": 12,
	  "members": [{"member": "a@h", "revision": 12}, {"member": "b@h", "revision": null}],
	  "settings": [
	    {"key": "crucible_max_concurrent", "value": 256, "desired": 64, "source": "operator", "pending": true},
	    {"key": "athanor_storage_bytes", "value": 1125899906842624, "source": "default", "pending": false},
	    {"key": "max_athanors", "value": null, "source": "deployment", "pending": false, "divergent": true},
	    {"key": "log_level", "value": "debug", "source": "operator", "pending": false}
	  ]
	}`
	if err := json.Unmarshal([]byte(payload), &result); err != nil {
		t.Fatal(err)
	}

	got := strings.Join(settingsLines(result), "\n")
	for _, want := range []string{
		"Store revision 12",
		"a@h observed 12",
		"b@h observed unknown",
		"(pending 64)",
		"1125899906842624",
		"(pinned on some members only)",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("want %q in:\n%s", want, got)
		}
	}

	for _, line := range settingsLines(result) {
		if strings.HasPrefix(line, "max_athanors") && !strings.Contains(line, "none") {
			t.Errorf("an unset value reads none: %q", line)
		}
		if strings.HasPrefix(line, "log_level") && strings.Contains(line, "pending") {
			t.Errorf("a live setting is never pending: %q", line)
		}
	}
}

func TestSettingsCommand_IsRegisteredUnderAdministration(t *testing.T) {
	c, _, err := rootCmd.Find([]string{"settings", "set"})
	if err != nil || c.Name() != "set" {
		t.Fatalf("want settings set registered, got %v, %v", c, err)
	}
	if settingsCmd.GroupID != "admin" {
		t.Errorf("want the admin group, got %q", settingsCmd.GroupID)
	}
}
