// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"

	"github.com/cyfr/codex/internal/ops"

	"github.com/spf13/cobra"
)

func init() {
	retentionSetCmd.Flags().Int("executions", 0, "Number of executions to keep per user")
	retentionSetCmd.Flags().Int("builds", 0, "Number of builds to keep per user")
	retentionSetCmd.Flags().StringArray("set", nil, "Set any retention key, as key=value (repeatable): a positive integer, or 0 for archive_days to archive no thread")

	retentionCleanupCmd.Flags().Bool("dry-run", false, "Count what the cleanup would delete, or for archive_days archive, without doing it")
	retentionCleanupCmd.Flags().String("type", "", "Retention key whose data to clean up, e.g. executions, builds, mcp_log_days or archive_days, which archives threads (default executions)")

	retentionCmd.AddCommand(retentionShowCmd)
	retentionCmd.AddCommand(retentionSetCmd)
	retentionCmd.AddCommand(retentionCleanupCmd)

	rootCmd.AddCommand(retentionCmd)
}

var retentionCmd = &cobra.Command{
	Use:     "retention",
	Short:   "Manage data retention policies",
	GroupID: "admin",
	Long:    "Show or set data retention settings, or trigger a manual cleanup of expired data; archive_days archives threads with no activity and deletes nothing.",
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
	Long: "Set how many executions and/or builds the athanor retains, or any retention key " +
		"(as `cyfr retention show` names them) with --set key=value.",
	Example: `  cyfr retention set --executions 100 --builds 50
  cyfr retention set --executions 200
  cyfr retention set --set mcp_log_days=14 --set archive_days=7
  cyfr retention set --set archive_days=0`,
	RunE: func(cmd *cobra.Command, args []string) error {
		values := map[string]int{}

		if cmd.Flags().Changed("executions") {
			v, _ := cmd.Flags().GetInt("executions")
			values["executions"] = v
		}
		if cmd.Flags().Changed("builds") {
			v, _ := cmd.Flags().GetInt("builds")
			values["builds"] = v
		}

		pairs, _ := cmd.Flags().GetStringArray("set")
		settings, err := retentionSettings(values, pairs)
		if err != nil {
			return err
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
	Long:  "Trigger a manual cleanup of data that exceeds retention limits; --type archive_days archives the threads with no activity for that many days instead.",
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

// retentionSettings adds each `--set key=value` pair to the values the
// named flags gave, and marshals them through the generated settings
// record, which refuses a key the retention tool does not declare.
func retentionSettings(values map[string]int, pairs []string) (ops.RetentionSetArgsSettings, error) {
	var settings ops.RetentionSetArgsSettings

	for _, pair := range pairs {
		key, raw, ok := strings.Cut(pair, "=")
		key = strings.TrimSpace(key)
		if !ok || key == "" {
			return settings, fmt.Errorf("--set takes key=value, got %q", pair)
		}
		value, err := strconv.Atoi(strings.TrimSpace(raw))
		if err != nil {
			return settings, fmt.Errorf("--set %s: %q is not an integer", key, raw)
		}
		if _, twice := values[key]; twice {
			return settings, fmt.Errorf("retention key %s is set twice", key)
		}
		values[key] = value
	}

	if len(values) == 0 {
		return settings, errors.New("Specify at least one of --executions, --builds or --set key=value")
	}

	encoded, err := json.Marshal(values)
	if err != nil {
		return settings, err
	}
	if err := json.Unmarshal(encoded, &settings); err != nil {
		return settings, fmt.Errorf("--set: %w", err)
	}
	return settings, nil
}
