// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

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
	rootCmd.AddCommand(removeCmd)
}

var removeCmd = &cobra.Command{
	Use:     "remove [type] [reference]",
	Short:   "Remove a component [interactive]",
	GroupID: "component",
	Long:    "Remove a component from the local registry. Also revokes its profiles and consents.\nRun without arguments for interactive selection.",
	Example: `  cyfr remove c:local.claude:0.2.0
  cyfr remove r local.sentiment:1.0.0
  cyfr remove`,
	Args: cobra.RangeArgs(0, 2),
	RunE: func(cmd *cobra.Command, args []string) error {
		client := newClient()
		var normalized string

		switch {
		case len(args) >= 1:
			args = joinTypeShorthand(args)
			var err error
			normalized, err = resolveComponentRef(cmd.Context(), client, args[0])
			if err != nil {
				return err
			}
		case prompt.IsInteractive(flagNoInteractive):
			opts, err := prompt.FetchComponents(cmd.Context(), client)
			if err != nil {
				return handleToolError(err)
			}
			if len(opts) == 0 {
				return errors.New("No components found. Nothing to remove.")
			}
			selected, err := prompt.SelectOne("Select a component to remove", opts)
			if err != nil {
				if prompt.IsAborted(err) {
					os.Exit(130)
				}
				return fmt.Errorf("Prompt failed: %v", err)
			}
			normalized = selected
		default:
			return errors.New("Usage: cyfr remove <reference>")
		}

		// Confirm before removing
		if prompt.IsInteractive(flagNoInteractive) {
			confirmed, err := prompt.Confirm(fmt.Sprintf("Remove component '%s'?", normalized))
			if err != nil {
				if prompt.IsAborted(err) {
					os.Exit(130)
				}
				return fmt.Errorf("Prompt failed: %v", err)
			}
			if !confirmed {
				fmt.Println("Cancelled.")
				return nil
			}
		}

		result, err := client.CallTool(cmd.Context(), "component", map[string]any{
			"action":    "delete",
			"reference": normalized,
		})
		if err != nil {
			return handleToolError(err, "Delete failed")
		}
		if flagJSON {
			output.JSON(result)
		} else {
			fmt.Printf("Deleted '%s'.\n", normalized)
			if note, ok := result["note"].(string); ok && note != "" {
				fmt.Printf("Note: %s\n", note)
			}
		}
		return nil
	},
}
