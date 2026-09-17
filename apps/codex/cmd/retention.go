// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"errors"
	"github.com/cyfr/codex/internal/ops"

	"github.com/spf13/cobra"
)

func init() {
	retentionSetCmd.Flags().Int("executions", 0, "Number of executions to keep per user")
	retentionSetCmd.Flags().Int("builds", 0, "Number of builds to keep per user")

	retentionCleanupCmd.Flags().Bool("dry-run", false, "Preview what would be cleaned up")
	retentionCleanupCmd.Flags().String("type", "", "Type of data to clean up (executions or builds)")

	retentionCmd.AddCommand(retentionShowCmd)
	retentionCmd.AddCommand(retentionSetCmd)
	retentionCmd.AddCommand(retentionCleanupCmd)

	rootCmd.AddCommand(retentionCmd)
}

var retentionCmd = &cobra.Command{
	Use:     "retention",
	Short:   "Manage data retention policies",
	GroupID: "admin",
	Long:    "Get or set data retention settings, or trigger a manual cleanup of expired data.",
}

var retentionShowCmd = &cobra.Command{
	Use:     "show",
	Short:   "Show current retention settings",
	Example: "  cyfr retention show",
	RunE: func(cmd *cobra.Command, args []string) error {
		client := newClient()
		result, err := client.CallTool(cmd.Context(), ops.Retention, ops.RetentionGetArgs{})
		if err != nil {
			return handleToolError(err)
		}
		return renderResult(result)
	},
}

var retentionSetCmd = &cobra.Command{
	Use:   "set",
	Short: "Update retention settings",
	Long:  "Set how many executions and/or builds to retain per user.",
	Example: `  cyfr retention set --executions 100 --builds 50
  cyfr retention set --executions 200`,
	RunE: func(cmd *cobra.Command, args []string) error {
		settings := ops.RetentionSetArgsSettings{}

		if cmd.Flags().Changed("executions") {
			v, _ := cmd.Flags().GetInt("executions")
			settings.Executions = ops.Value(v)
		}
		if cmd.Flags().Changed("builds") {
			v, _ := cmd.Flags().GetInt("builds")
			settings.Builds = ops.Value(v)
		}

		if settings.Executions.IsZero() && settings.Builds.IsZero() {
			return errors.New("Specify at least one of --executions or --builds")
		}

		client := newClient()
		result, err := client.CallTool(cmd.Context(), ops.Retention, ops.RetentionSetArgs{Settings: settings})
		if err != nil {
			return handleToolError(err)
		}
		return renderResult(result)
	},
}

var retentionCleanupCmd = &cobra.Command{
	Use:   "cleanup",
	Short: "Run retention cleanup",
	Long:  "Trigger a manual cleanup of data that exceeds retention limits.",
	Example: `  cyfr retention cleanup
  cyfr retention cleanup --type executions
  cyfr retention cleanup --dry-run`,
	RunE: func(cmd *cobra.Command, args []string) error {
		client := newClient()

		toolArgs := ops.RetentionCleanupArgs{}

		if cmd.Flags().Changed("type") {
			v, _ := cmd.Flags().GetString("type")
			toolArgs.CleanupType = ops.Value(v)
		}
		if dryRun, _ := cmd.Flags().GetBool("dry-run"); cmd.Flags().Changed("dry-run") {
			toolArgs.DryRun = ops.Value(dryRun)
		}

		result, err := client.CallTool(cmd.Context(), ops.Retention, toolArgs)
		if err != nil {
			return handleToolError(err)
		}
		return renderResult(result)
	},
}
