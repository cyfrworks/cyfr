// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"encoding/json"
	"fmt"
	"github.com/cyfr/codex/internal/ops"

	"github.com/cyfr/codex/internal/output"

	"github.com/spf13/cobra"
)

func init() {

	scheduleGetCmd.Flags().Bool("json", false, "") // inherits from root but explicit for clarity
	scheduleGetCmd.Flags().MarkHidden("json")

	scheduleUpdateCmd.Flags().String("name", "", "New schedule name")
	scheduleUpdateCmd.Flags().String("cron", "", "New cron expression")
	scheduleUpdateCmd.Flags().String("ref", "", "New component reference")
	scheduleUpdateCmd.Flags().String("profile", "", "Replacement consented execution profile ID")
	scheduleUpdateCmd.Flags().String("input", "", "New JSON input")
	addMissedRunsFlags(scheduleUpdateCmd)

	scheduleCmd.AddCommand(scheduleListCmd)
	scheduleCmd.AddCommand(scheduleGetCmd)
	scheduleCmd.AddCommand(scheduleUpdateCmd)
	scheduleCmd.AddCommand(schedulePauseCmd)
	scheduleCmd.AddCommand(scheduleResumeCmd)
	scheduleCmd.AddCommand(scheduleDeleteCmd)

	rootCmd.AddCommand(scheduleCmd)
}

var scheduleCmd = &cobra.Command{
	Use:     "schedule",
	Short:   "Manage recurring component schedules",
	GroupID: "component",
	Long:    `List, update, pause, resume and delete recurring cron schedules for WASM component execution. Make one on CYFR's Schedules page.`,
}

var scheduleListCmd = &cobra.Command{
	Use:   "list",
	Short: "List cron schedules",
	RunE: func(cmd *cobra.Command, args []string) error {
		client := newClient()

		result, err := client.CallTool(cmd.Context(), ops.Schedule, ops.ScheduleListArgs{})
		if err != nil {
			return handleToolError(err)
		}
		return renderResult(result)
	},
}

var scheduleGetCmd = &cobra.Command{
	Use:   "get <id|name>",
	Short: "Show schedule details",
	Example: `  cyfr schedule get my-schedule
  cyfr schedule get 550e8400-e29b-41d4-a716-446655440000`,
	Args: cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		client := newClient()

		result, err := client.CallTool(cmd.Context(), ops.Schedule, ops.ScheduleGetArgs{ScheduleId: args[0]})
		if err != nil {
			return handleToolError(err)
		}
		return renderResult(result)
	},
}

var scheduleUpdateCmd = &cobra.Command{
	Use:   "update <id|name>",
	Short: "Update a cron schedule",
	Long:  "Update one or more fields of an existing schedule. Only explicitly set flags are sent.",
	Example: `  cyfr schedule update my-schedule --cron "0 */2 * * *"
  cyfr schedule update my-schedule --name new-name
  cyfr schedule update my-schedule --input '{"key":"new-value"}'
  cyfr schedule update my-schedule --missed-runs catch_up --catch-up-limit 3
  cyfr schedule update my-schedule --missed-runs skip`,
	Args: cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		client := newClient()

		toolArgs := ops.ScheduleUpdateArgs{ScheduleId: args[0]}
		if cmd.Flags().Changed("profile") {
			profileID, _ := cmd.Flags().GetString("profile")
			toolArgs.ProfileId = ops.Value(profileID)
		}

		if cmd.Flags().Changed("name") {
			v, _ := cmd.Flags().GetString("name")
			toolArgs.Name = ops.Value(v)
		}
		if cmd.Flags().Changed("cron") {
			v, _ := cmd.Flags().GetString("cron")
			toolArgs.CronExpression = ops.Value(v)
		}
		if cmd.Flags().Changed("ref") {
			v, _ := cmd.Flags().GetString("ref")
			toolArgs.Reference = ops.Value(v)
		}
		if cmd.Flags().Changed("input") {
			inputStr, _ := cmd.Flags().GetString("input")
			var inputMap map[string]any
			if err := json.Unmarshal([]byte(inputStr), &inputMap); err != nil {
				return fmt.Errorf("Invalid JSON input: %w", err)
			}
			toolArgs.Input = ops.Nullable(inputMap)
		}
		toolArgs.MissedRuns, toolArgs.CatchUpLimit = missedRunsFlags(cmd)

		result, err := client.CallTool(cmd.Context(), ops.Schedule, toolArgs)
		if err != nil {
			return handleToolError(err)
		}

		if flagJSON {
			output.JSON(result)
		} else {
			fmt.Println("Schedule updated.")
			output.KeyValue(result)
		}
		return nil
	},
}

var schedulePauseCmd = &cobra.Command{
	Use:   "pause <id|name>",
	Short: "Pause a cron schedule",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		client := newClient()

		result, err := client.CallTool(cmd.Context(), ops.Schedule, ops.SchedulePauseArgs{ScheduleId: args[0]})
		if err != nil {
			return handleToolError(err)
		}

		if flagJSON {
			output.JSON(result)
		} else {
			fmt.Println("Schedule paused.")
			output.KeyValue(result)
		}
		return nil
	},
}

var scheduleResumeCmd = &cobra.Command{
	Use:   "resume <id|name>",
	Short: "Resume a paused cron schedule",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		client := newClient()

		result, err := client.CallTool(cmd.Context(), ops.Schedule, ops.ScheduleResumeArgs{ScheduleId: args[0]})
		if err != nil {
			return handleToolError(err)
		}

		if flagJSON {
			output.JSON(result)
		} else {
			fmt.Println("Schedule resumed.")
			output.KeyValue(result)
		}
		return nil
	},
}

var scheduleDeleteCmd = &cobra.Command{
	Use:   "delete <id|name>",
	Short: "Delete a cron schedule",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		client := newClient()

		result, err := client.CallTool(cmd.Context(), ops.Schedule, ops.ScheduleDeleteArgs{ScheduleId: args[0]})
		if err != nil {
			return handleToolError(err)
		}

		if flagJSON {
			output.JSON(result)
		} else {
			fmt.Println("Schedule deleted.")
		}
		return nil
	},
}

// addMissedRunsFlags declares a schedule's missed-run policy on create and
// update: what becomes of due times the server missed.
func addMissedRunsFlags(cmd *cobra.Command) {
	cmd.Flags().String("missed-runs", "", "Missed due times: skip (default) or catch_up")
	cmd.Flags().Int("catch-up-limit", 0, "How many missed times one catch-up fires (with --missed-runs catch_up)")
}

// missedRunsFlags reads the two flags as set: one not given is not sent, so
// an update keeps what the schedule holds. The tool decides what a policy
// and a limit may be, and refuses a catch_up without one.
func missedRunsFlags(cmd *cobra.Command) (ops.Field[string], ops.Field[int]) {
	var policy ops.Field[string]
	var limit ops.Field[int]
	if cmd.Flags().Changed("missed-runs") {
		v, _ := cmd.Flags().GetString("missed-runs")
		policy = ops.Value(v)
	}
	if cmd.Flags().Changed("catch-up-limit") {
		v, _ := cmd.Flags().GetInt("catch-up-limit")
		limit = ops.Value(v)
	}
	return policy, limit
}
