package cmd

import (
	"errors"
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
	RunE: func(cmd *cobra.Command, args []string) error {
		client := newClient()
		result, err := client.CallTool(cmd.Context(), "aqua", map[string]any{
			"action": "list",
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

var aquaGetCmd = &cobra.Command{
	Use:   "get [name]",
	Short: "Display an agent prompt or guide",
	Long:  "Retrieve and display an AQUA agent prompt or documentation guide by name. Run without arguments for interactive selection.",
	Example: `  cyfr aqua get component-guide
  cyfr aqua get tincture-guide
  cyfr aqua get aqua_builder --json`,
	Args: cobra.RangeArgs(0, 1),
	RunE: func(cmd *cobra.Command, args []string) error {
		var name string

		switch {
		case len(args) >= 1:
			name = args[0]
		case prompt.IsInteractive(flagNoInteractive):
			client := newClient()
			opts, err := prompt.FetchGuides(cmd.Context(), client)
			if err != nil {
				return handleToolError(err)
			}
			if len(opts) == 0 {
				return errors.New("No agents or guides found.")
			}
			selected, err := prompt.SelectOne("Select an agent or guide", opts)
			if err != nil {
				if prompt.IsAborted(err) {
					os.Exit(130)
				}
				return fmt.Errorf("Prompt failed: %v", err)
			}
			name = selected
		default:
			return errors.New("Usage: cyfr aqua get <name>")
		}

		client := newClient()
		result, err := client.CallTool(cmd.Context(), "aqua", map[string]any{
			"action": "get",
			"name":   name,
		})
		if err != nil {
			return handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			fmt.Println(result["content"])
		}
		return nil
	},
}
