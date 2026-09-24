// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestRetentionSettings_SetPairsJoinTheNamedFlags(t *testing.T) {
	settings, err := retentionSettings(
		map[string]int{"executions": 100},
		[]string{"mcp_log_days=14", " projection_tombstone_days = 3 "},
	)
	if err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	encoded, err := json.Marshal(settings)
	if err != nil {
		t.Fatal(err)
	}
	want := `{"executions":100,"mcp_log_days":14,"projection_tombstone_days":3}`
	if string(encoded) != want {
		t.Errorf("want %s, got %s", want, encoded)
	}
}

func TestRetentionSettings_RefusesAnUndeclaredKey(t *testing.T) {
	_, err := retentionSettings(map[string]int{}, []string{"made_up=3"})
	if err == nil || !strings.Contains(err.Error(), "made_up") {
		t.Errorf("want an unknown-key error naming made_up, got %v", err)
	}
}

func TestRetentionSettings_RefusesAMalformedPair(t *testing.T) {
	for _, pair := range []string{"executions", "=5", "executions=many"} {
		if _, err := retentionSettings(map[string]int{}, []string{pair}); err == nil {
			t.Errorf("%q: want an error, got nil", pair)
		}
	}
}

func TestRetentionSettings_RefusesAKeySetTwice(t *testing.T) {
	_, err := retentionSettings(map[string]int{"builds": 5}, []string{"builds=6"})
	if err == nil || !strings.Contains(err.Error(), "twice") {
		t.Errorf("want a set-twice error, got %v", err)
	}
}

func TestRetentionSettings_NeedsAtLeastOneValue(t *testing.T) {
	if _, err := retentionSettings(map[string]int{}, nil); err == nil {
		t.Error("want an error for an empty set, got nil")
	}
}
