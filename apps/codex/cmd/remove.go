package cmd

import (
	"fmt"
	"os"

	"github.com/cyfr/codex/internal/output"
	"github.com/cyfr/codex/internal/prompt"
	"github.com/spf13/cobra"
)

func init() {
	rootCmd.AddCommand(removeCmd)
}

var removeCmd = &cobra.Command{
	Use:     "remove [type] [reference]",
	Short:   "Remove a component [interactive]",
	GroupID: "component",
	Long:    "Remove a component from the local registry. Also removes its associated policies and secret grants.\nRun without arguments for interactive selection.",
	Example: `  cyfr remove c:local.claude:0.2.0
  cyfr remove r local.sentiment:1.0.0
  cyfr remove`,
	Args: cobra.RangeArgs(0, 2),
	Run: func(cmd *cobra.Command, args []string) {
		client := newClient()
		var normalized string

		switch {
		case len(args) >= 1:
			args = joinTypeShorthand(args)
			normalized = resolveComponentRef(client, args[0])
		case prompt.IsInteractive(flagNoInteractive):
			opts, err := prompt.FetchComponents(client)
			if err != nil {
				handleToolError(err)
			}
			if len(opts) == 0 {
				output.Error("No components found. Nothing to remove.")
			}
			selected, err := prompt.SelectOne("Select a component to remove", opts)
			if err != nil {
				if prompt.IsAborted(err) {
					os.Exit(130)
				}
				output.Errorf("Prompt failed: %v", err)
			}
			normalized = selected
		default:
			output.Error("Usage: cyfr remove <reference>")
		}

		// Confirm before removing
		if prompt.IsInteractive(flagNoInteractive) {
			confirmed, err := prompt.Confirm(fmt.Sprintf("Remove component '%s'?", normalized))
			if err != nil {
				if prompt.IsAborted(err) {
					os.Exit(130)
				}
				output.Errorf("Prompt failed: %v", err)
			}
			if !confirmed {
				fmt.Println("Cancelled.")
				return
			}
		}

		result, err := client.CallTool("component", map[string]any{
			"action":    "remove",
			"reference": normalized,
		})
		if err != nil {
			handleToolError(err, "Remove failed")
		}
		if flagJSON {
			output.JSON(result)
		} else {
			fmt.Printf("Removed '%s'.\n", normalized)
			if note, ok := result["note"].(string); ok && note != "" {
				fmt.Printf("Note: %s\n", note)
			}
		}
	},
}
