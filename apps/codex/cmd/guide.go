package cmd

import (
	"fmt"
	"os"

	"github.com/cyfr/codex/internal/output"
	"github.com/cyfr/codex/internal/prompt"
	"github.com/spf13/cobra"
)

func init() {
	rootCmd.AddCommand(aquaCmd)
	aquaCmd.AddCommand(aquaListCmd)
	aquaCmd.AddCommand(aquaGetCmd)
}

var aquaCmd = &cobra.Command{
	Use:     "aqua",
	Short:   "AQUA agent system",
	GroupID: "admin",
	Long:    "Manage the AQUA agent system — orchestrators, sub-agents, prompts, and documentation guides.",
}

var aquaListCmd = &cobra.Command{
	Use:   "list",
	Short: "List available agents and guides",
	Long:  "List all available AQUA agents and documentation guides.",
	Example: `  cyfr aqua list
  cyfr aqua list --json`,
	Run: func(cmd *cobra.Command, args []string) {
		client := newClient()
		result, err := client.CallTool("aqua", map[string]any{
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

var aquaGetCmd = &cobra.Command{
	Use:   "get [name]",
	Short: "Display an agent prompt or guide",
	Long:  "Retrieve and display an AQUA agent prompt or documentation guide by name. Run without arguments for interactive selection.",
	Example: `  cyfr aqua get component-guide
  cyfr aqua get aqua_builder --json`,
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
				output.Error("No agents or guides found.")
			}
			selected, err := prompt.SelectOne("Select an agent or guide", opts)
			if err != nil {
				if prompt.IsAborted(err) {
					os.Exit(130)
				}
				output.Errorf("Prompt failed: %v", err)
			}
			name = selected
		default:
			output.Error("Usage: cyfr aqua get <name>")
		}

		client := newClient()
		result, err := client.CallTool("aqua", map[string]any{
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
