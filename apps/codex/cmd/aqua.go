// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"context"
	"fmt"

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
	Long:    "Manage the estate's AQUA — its soul, its roles, their prompts, and the documentation guides.",
}

var aquaListCmd = &cobra.Command{
	Use:   "list",
	Short: "List the soul, roles and guides",
	Long:  "List the estate's AQUA soul and roles, and the documentation guides.",
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
		return renderResult(result)
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
		name, err := pickTarget(cmd.Context(), args, selector{
			Title: "Select an agent or guide",
			Empty: "No agents or guides found.",
			Usage: "Usage: cyfr aqua get <name>",
			Fetch: func(ctx context.Context) ([]prompt.Option, error) {
				return prompt.FetchGuides(ctx, newClient())
			},
		})
		if err != nil || name == "" {
			return err
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
