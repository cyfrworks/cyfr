package cmd

import (
	"fmt"
	"os"

	"github.com/cyfr/codex/internal/output"
	"github.com/cyfr/codex/internal/prompt"
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
	GroupID: "admin",
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
	Use:   "get [name]",
	Short: "Display a guide",
	Long:  "Retrieve and display a CYFR documentation guide by name. Run without arguments for interactive selection.",
	Example: `  cyfr guide get component-guide
  cyfr guide get integration-guide --json`,
	Args: cobra.RangeArgs(0, 1),
	Run: func(cmd *cobra.Command, args []string) {
		var name string

		switch {
		case len(args) >= 1:
			name = args[0]
		case prompt.IsInteractive(flagNoInteractive):
			client := newClient()
			opts, err := prompt.FetchGuides(client)
			if err != nil {
				handleToolError(err)
			}
			if len(opts) == 0 {
				output.Error("No guides found.")
			}
			selected, err := prompt.SelectOne("Select a guide", opts)
			if err != nil {
				if prompt.IsAborted(err) {
					os.Exit(130)
				}
				output.Errorf("Prompt failed: %v", err)
			}
			name = selected
		default:
			output.Error("Usage: cyfr guide get <name>")
		}

		client := newClient()
		result, err := client.CallTool("guide", map[string]any{
			"action": "get",
			"name":   name,
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
	Use:   "readme [reference]",
	Short: "Display a component's README",
	Long:  "Retrieve and display the README.md for a specific component by reference. Run without arguments for interactive selection.",
	Example: `  cyfr guide readme c:local.claude:0.1.0
  cyfr guide readme local.sentiment:1.0.0 --json`,
	Args: cobra.RangeArgs(0, 1),
	Run: func(cmd *cobra.Command, args []string) {
		client := newClient()
		var reference string

		switch {
		case len(args) >= 1:
			reference = resolveComponentRef(client, args[0])
		case prompt.IsInteractive(flagNoInteractive):
			opts, err := prompt.FetchComponents(client)
			if err != nil {
				handleToolError(err)
			}
			if len(opts) == 0 {
				output.Error("No components found. Register one first.")
			}
			selected, err := prompt.SelectOne("Select a component", opts)
			if err != nil {
				if prompt.IsAborted(err) {
					os.Exit(130)
				}
				output.Errorf("Prompt failed: %v", err)
			}
			reference = selected
		default:
			output.Error("Usage: cyfr guide readme <reference>")
		}

		result, err := client.CallTool("guide", map[string]any{
			"action":    "readme",
			"reference": reference,
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
