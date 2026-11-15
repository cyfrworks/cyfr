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

// The arguments a schedule command sends for its missed-run flags, as the
// tool receives them.
func missedRunsSent(t *testing.T, argv ...string) map[string]any {
	t.Helper()
	cmd := &cobra.Command{Use: "probe"}
	addMissedRunsFlags(cmd)
	if err := cmd.ParseFlags(argv); err != nil {
		t.Fatalf("parse %v: %v", argv, err)
	}

	args := ops.ScheduleUpdateArgs{ScheduleId: "sched_x"}
	args.MissedRuns, args.CatchUpLimit = missedRunsFlags(cmd)

	raw, err := json.Marshal(args)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	var sent map[string]any
	if err := json.Unmarshal(raw, &sent); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	return sent
}

func TestScheduleMissedRunsFlags_SentAsSet(t *testing.T) {
	sent := missedRunsSent(t, "--missed-runs", "catch_up", "--catch-up-limit", "3")
	if sent["missed_runs"] != "catch_up" || sent["catch_up_limit"] != float64(3) {
		t.Errorf("want missed_runs=catch_up catch_up_limit=3, got %v", sent)
	}

	// A limit of 0 is sent as given: the tool refuses it, not the CLI.
	sent = missedRunsSent(t, "--missed-runs", "catch_up", "--catch-up-limit", "0")
	if sent["catch_up_limit"] != float64(0) {
		t.Errorf("want catch_up_limit=0 sent, got %v", sent)
	}

	sent = missedRunsSent(t, "--missed-runs", "skip")
	if _, ok := sent["catch_up_limit"]; ok || sent["missed_runs"] != "skip" {
		t.Errorf("want missed_runs=skip and no limit, got %v", sent)
	}
}

func TestScheduleMissedRunsFlags_UnsetSendsNothing(t *testing.T) {
	sent := missedRunsSent(t)
	for _, key := range []string{"missed_runs", "catch_up_limit"} {
		if _, ok := sent[key]; ok {
			t.Errorf("an update naming no policy sent %s: %v", key, sent)
		}
	}
}

// What a schedule runs and the profile it fires under are a person's to
// bind, on the Schedules page: update offers no flag for either, and keeps
// the ones a key may use.
func TestScheduleUpdate_NoRepointFlags(t *testing.T) {
	for _, name := range []string{"ref", "profile"} {
		if scheduleUpdateCmd.Flags().Lookup(name) != nil {
			t.Errorf("cyfr schedule update still declares --%s", name)
		}
	}
	for _, name := range []string{"name", "cron", "input", "missed-runs", "catch-up-limit"} {
		if scheduleUpdateCmd.Flags().Lookup(name) == nil {
			t.Errorf("cyfr schedule update lost --%s", name)
		}
	}

	help := scheduleUpdateCmd.UsageString() + scheduleUpdateCmd.Long + scheduleUpdateCmd.Example
	for _, flag := range []string{"--ref", "--profile"} {
		if strings.Contains(help, flag) {
			t.Errorf("cyfr schedule update's help names %s:\n%s", flag, help)
		}
	}

	cmd := &cobra.Command{Use: "probe"}
	cmd.Flags().AddFlagSet(scheduleUpdateCmd.Flags())
	for _, flag := range []string{"--ref=c:local.x", "--profile=prof_x"} {
		if err := cmd.ParseFlags([]string{flag}); err == nil {
			t.Errorf("%s was accepted", flag)
		}
	}
}
