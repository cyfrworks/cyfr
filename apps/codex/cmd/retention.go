package cmd

import (
	"github.com/cyfr/codex/internal/output"
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
	Run: func(cmd *cobra.Command, args []string) {
		client := newClient()
		result, err := client.CallTool("retention", map[string]any{
			"action": "get",
		})
		if err != nil {
			handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			output.KeyValue(result)
		}
	},
}

var retentionSetCmd = &cobra.Command{
	Use:   "set",
	Short: "Update retention settings",
	Long:  "Set how many executions and/or builds to retain per user.",
	Example: `  cyfr retention set --executions 100 --builds 50
  cyfr retention set --executions 200`,
	Run: func(cmd *cobra.Command, args []string) {
		settings := map[string]any{}

		if cmd.Flags().Changed("executions") {
			v, _ := cmd.Flags().GetInt("executions")
			settings["executions"] = v
		}
		if cmd.Flags().Changed("builds") {
			v, _ := cmd.Flags().GetInt("builds")
			settings["builds"] = v
		}

		if len(settings) == 0 {
			output.Error("Specify at least one of --executions or --builds")
		}

		client := newClient()
		result, err := client.CallTool("retention", map[string]any{
			"action":   "set",
			"settings": settings,
		})
		if err != nil {
			handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			output.KeyValue(result)
		}
	},
}

var retentionCleanupCmd = &cobra.Command{
	Use:   "cleanup",
	Short: "Run retention cleanup",
	Long:  "Trigger a manual cleanup of data that exceeds retention limits.",
	Example: `  cyfr retention cleanup
  cyfr retention cleanup --type executions
  cyfr retention cleanup --dry-run`,
	Run: func(cmd *cobra.Command, args []string) {
		client := newClient()

		toolArgs := map[string]any{
			"action": "cleanup",
		}

		if cmd.Flags().Changed("type") {
			v, _ := cmd.Flags().GetString("type")
			toolArgs["cleanup_type"] = v
		}
		if dryRun, _ := cmd.Flags().GetBool("dry-run"); dryRun {
			toolArgs["dry_run"] = true
		}

		result, err := client.CallTool("retention", toolArgs)
		if err != nil {
			handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			output.KeyValue(result)
		}
	},
}
