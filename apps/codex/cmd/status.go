package cmd

import (
	"github.com/cyfr/codex/internal/output"
	"github.com/spf13/cobra"
)

func init() {
	statusCmd.Flags().String("scope", "all", "Check specific service: opus, sanctum, emissary, arca, compendium, locus")
	rootCmd.AddCommand(statusCmd)
	rootCmd.AddCommand(notifyCmd)
}

var statusCmd = &cobra.Command{
	Use:     "status",
	Short:   "Check system health",
	GroupID: "start",
	Long:    "Query the health of each CYFR service. Use --scope to check a single service instead of all of them.",
	Example: `  cyfr status
  cyfr status --scope sanctum
  cyfr status --json`,
	Run: func(cmd *cobra.Command, args []string) {
		scope, _ := cmd.Flags().GetString("scope")

		client := newClient()
		result, err := client.CallTool("system", map[string]any{
			"action": "status",
			"scope":  scope,
		})
		if err != nil {
			output.Errorf("Failed to connect: %v", err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			output.KeyValue(result)
		}
	},
}

var notifyCmd = &cobra.Command{
	Use:     "notify <event> <target>",
	Short:   "Send a webhook notification",
	GroupID: "advanced",
	Long:    "Dispatch a webhook event to the given target URL. Useful for integrating CYFR events into external systems like Slack or PagerDuty.",
	Example: `  cyfr notify deployment.complete https://hooks.slack.com/T0/B0/xxx
  cyfr notify audit.export https://example.com/webhook`,
	Args: cobra.ExactArgs(2),
	Run: func(cmd *cobra.Command, args []string) {
		client := newClient()
		result, err := client.CallTool("system", map[string]any{
			"action": "notify",
			"event":  args[0],
			"target": args[1],
		})
		if err != nil {
			output.Errorf("Failed: %v", err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			output.KeyValue(result)
		}
	},
}
