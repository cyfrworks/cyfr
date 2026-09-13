// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"context"
	"fmt"
	"github.com/cyfr/codex/internal/ops"

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
		normalized, err := pickTarget(cmd.Context(), joinTypeShorthand(args), selector{
			Title: "Select a component to remove",
			Empty: "No components found. Nothing to remove.",
			Usage: "Usage: cyfr remove <reference>",
			Fetch: func(ctx context.Context) ([]prompt.Option, error) {
				return prompt.FetchComponents(ctx, client)
			},
			Normalize: func(ctx context.Context, arg string) (string, error) {
				return resolveComponentRef(ctx, client, arg)
			},
		})
		if err != nil {
			return err
		}

		// Confirm before removing — for an argument-given ref too, not just
		// a picked one.
		if prompt.IsInteractive(flagNoInteractive) {
			confirmed, err := prompt.Confirm(fmt.Sprintf("Remove component '%s'?", normalized))
			if err != nil {
				if prompt.IsAborted(err) {
					return prompt.ErrAborted
				}
				return fmt.Errorf("Prompt failed: %w", err)
			}
			if !confirmed {
				fmt.Println("Cancelled.")
				return nil
			}
		}

		result, err := client.CallTool(cmd.Context(), ops.Component, map[string]any{
			"action":    ops.ComponentDelete,
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
