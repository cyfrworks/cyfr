package cmd

import (
	"fmt"
	"os"

	"github.com/cyfr/codex/internal/output"
	"github.com/cyfr/codex/internal/version"
	"github.com/spf13/cobra"
)

func init() {
	statusCmd.Flags().String("scope", "all", "Check specific service: opus, sanctum, emissary, arca, compendium, registry")
	rootCmd.AddCommand(statusCmd)
	rootCmd.AddCommand(notifyCmd)
}

var statusCmd = &cobra.Command{
	Use:     "status",
	Short:   "Check system health",
	GroupID: "identity",
	Long:    "Query the health of each CYFR service. Use --scope to check a single service instead of all of them.",
	Example: `  cyfr status
  cyfr status --scope sanctum
  cyfr status --json`,
	RunE: func(cmd *cobra.Command, args []string) error {
		scope, _ := cmd.Flags().GetString("scope")

		client := newClient()
		result, err := client.CallTool(cmd.Context(), "system", map[string]any{
			"action": "status",
			"scope":  scope,
		})
		if err != nil {
			return handleToolError(err, "Failed to connect")
		}
		if flagJSON {
			result["cli_version"] = version.Version
			result["cli_commit"] = version.Commit
			result["cli_date"] = version.Date
			output.JSON(result)
		} else {
			fmt.Printf("cyfr v%s (commit: %s, built: %s)\n\n", version.Version, version.Commit, version.Date)
			output.KeyValue(result)

			// Hint if registry is not reachable
			if services, ok := result["services"].(map[string]any); ok {
				if regStatus, ok := services["registry"].(string); ok && regStatus != "ok" {
					fmt.Fprintf(os.Stderr, "\nRegistry is %s. Run 'cyfr login' to authenticate or check your connection.\n", regStatus)
				}
			}

			if n := upgradeNotice(); n != "" {
				fmt.Println("\n" + n)
			}
		}
		return nil
	},
}

var notifyCmd = &cobra.Command{
	Use:     "notify <event> <target>",
	Short:   "Send a webhook notification",
	GroupID: "admin",
	Long:    "Dispatch a webhook event to the given target URL. Useful for integrating CYFR events into external systems like Slack or PagerDuty.",
	Example: `  cyfr notify deployment.complete https://hooks.slack.com/T0/B0/xxx
  cyfr notify audit.export https://example.com/webhook`,
	Args: cobra.ExactArgs(2),
	RunE: func(cmd *cobra.Command, args []string) error {
		client := newClient()
		result, err := client.CallTool(cmd.Context(), "system", map[string]any{
			"action": "notify",
			"event":  args[0],
			"target": args[1],
		})
		if err != nil {
			return handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			output.KeyValue(result)
		}
		return nil
	},
}
