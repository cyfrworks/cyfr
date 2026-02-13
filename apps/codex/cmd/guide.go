package cmd

import (
	"fmt"

	"github.com/cyfr/codex/internal/output"
	"github.com/spf13/cobra"
)

func init() {
	rootCmd.AddCommand(guideCmd)
	guideCmd.AddCommand(guideListCmd)
	guideCmd.AddCommand(guideGetCmd)
	guideCmd.AddCommand(guideReadmeCmd)
}

var guideCmd = &cobra.Command{
	Use:     "guide",
	Short:   "Access documentation guides",
	GroupID: "start",
	Long:    "Access CYFR documentation guides and component READMEs.",
}

var guideListCmd = &cobra.Command{
	Use:   "list",
	Short: "List available guides",
	Long:  "List all available CYFR documentation guides.",
	Example: `  cyfr guide list
  cyfr guide list --json`,
	Run: func(cmd *cobra.Command, args []string) {
		client := newClient()
		result, err := client.CallTool("guide", map[string]any{
			"action": "list",
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

var guideGetCmd = &cobra.Command{
	Use:   "get <name>",
	Short: "Display a guide",
	Long:  "Retrieve and display a CYFR documentation guide by name.",
	Example: `  cyfr guide get component-guide
  cyfr guide get integration-guide --json`,
	Args: cobra.ExactArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		client := newClient()
		result, err := client.CallTool("guide", map[string]any{
			"action": "get",
			"name":   args[0],
		})
		if err != nil {
			handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			fmt.Println(result["content"])
		}
	},
}

var guideReadmeCmd = &cobra.Command{
	Use:   "readme <reference>",
	Short: "Display a component's README",
	Long:  "Retrieve and display the README.md for a specific component by reference.",
	Example: `  cyfr guide readme c:local.claude:0.1.0
  cyfr guide readme local.sentiment:1.0.0 --json`,
	Args: cobra.ExactArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		client := newClient()
		result, err := client.CallTool("guide", map[string]any{
			"action":    "readme",
			"reference": args[0],
		})
		if err != nil {
			handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			fmt.Println(result["content"])
		}
	},
}
