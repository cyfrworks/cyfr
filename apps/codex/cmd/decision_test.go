// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/spf13/pflag"
)

// listFlags is a fresh set of `cyfr decision list`'s flags, set as given.
func listFlags(t *testing.T, set map[string]string) *pflag.FlagSet {
	t.Helper()
	flags := pflag.NewFlagSet("list", pflag.ContinueOnError)
	addDecisionListFlags(flags)
	for name, value := range set {
		if err := flags.Set(name, value); err != nil {
			t.Fatalf("set --%s: %v", name, err)
		}
	}
	return flags
}

func encode(t *testing.T, args any) string {
	t.Helper()
	encoded, err := json.Marshal(args)
	if err != nil {
		t.Fatal(err)
	}
	return string(encoded)
}

func TestDecisionListArgs_MapsEachFilterFlag(t *testing.T) {
	args, err := decisionListArgs(listFlags(t, map[string]string{
		"tool":          "storage",
		"admission":     "refused",
		"refusal-class": "forbidden",
		"since":         "2026-09-01T00:00:00Z",
		"request":       "req_01abc",
		"limit":         "5",
	}))
	if err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	want := `{"action":"list","request_id":"req_01abc","tool":"storage","admission":"refused",` +
		`"refusal_class":"forbidden","since":"2026-09-01T00:00:00Z","limit":5}`
	if got := encode(t, args); got != want {
		t.Errorf("want %s, got %s", want, got)
	}
}

func TestDecisionListArgs_SendsOnlyTheActionByDefault(t *testing.T) {
	args, err := decisionListArgs(listFlags(t, nil))
	if err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	if got := encode(t, args); got != `{"action":"list"}` {
		t.Errorf("want only the action, got %s", got)
	}
}

func TestDecisionListArgs_GlobalReadsListGlobal(t *testing.T) {
	args, err := decisionListArgs(listFlags(t, map[string]string{
		"global":    "true",
		"athanor":   "none",
		"admission": "refused",
	}))
	if err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	want := `{"action":"list_global","admission":"refused","athanor_id":"none"}`
	if got := encode(t, args); got != want {
		t.Errorf("want %s, got %s", want, got)
	}
}

func TestDecisionListArgs_AthanorNeedsGlobal(t *testing.T) {
	_, err := decisionListArgs(listFlags(t, map[string]string{"athanor": "ath_1"}))
	if err == nil || !strings.Contains(err.Error(), "--global") {
		t.Errorf("want an error naming --global, got %v", err)
	}
}

func TestDecisionGetArgs(t *testing.T) {
	if got := encode(t, decisionGetArgs("call_1", false)); got != `{"action":"get","call_id":"call_1"}` {
		t.Errorf("tenant get: got %s", got)
	}
	if got := encode(t, decisionGetArgs("call_1", true)); got != `{"action":"get_global","call_id":"call_1"}` {
		t.Errorf("global get: got %s", got)
	}
}

func TestDecisionRows_BlankForAbsentFields(t *testing.T) {
	rows := decisionRows(map[string]any{"decisions": []any{
		map[string]any{
			"call_id": "call_1", "tool": "storage", "action": "get", "admission": "admitted",
			"refusal_class": nil, "completion": "succeeded", "inserted_at": "2026-09-25T00:00:00Z",
		},
		"not a decision",
	}})
	if len(rows) != 1 {
		t.Fatalf("want one row, got %d", len(rows))
	}
	if rows[0]["refusal_class"] != "" || rows[0]["completion"] != "succeeded" || rows[0]["call_id"] != "call_1" {
		t.Errorf("unexpected row %v", rows[0])
	}
}

// TestDecisionCommandTree pins the surface and the help's words: the id a
// decision is read by is its call id, and the global forms are flags.
func TestDecisionCommandTree(t *testing.T) {
	for _, name := range []string{"list", "get", "correlate"} {
		findCommand(t, "decision "+name)
	}
	if findCommand(t, "decision list").Flags().Lookup("global") == nil ||
		findCommand(t, "decision get").Flags().Lookup("global") == nil {
		t.Error("decision list and get take --global")
	}
	if get := findCommand(t, "decision get"); get.Use != "get <call_id>" || !strings.Contains(get.Long, "call_") {
		t.Errorf("decision get reads a call id, got %q / %q", get.Use, get.Long)
	}
	if log := findCommand(t, "log get"); log.Use != "get <call_id>" || !strings.Contains(log.Long, "call_") {
		t.Errorf("log get reads the row's call id, got %q / %q", log.Use, log.Long)
	}
	if !strings.Contains(findCommand(t, "log correlate").Long, "decisions") {
		t.Error("log correlate's help names the decisions it answers")
	}
}
