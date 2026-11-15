// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"fmt"
	"github.com/cyfr/codex/internal/ops"
	"slices"

	"github.com/cyfr/codex/internal/output"
	"github.com/spf13/cobra"
)

func init() {
	athanorCmd.AddCommand(athanorGetCmd)
	rootCmd.AddCommand(athanorCmd)
}

var athanorCmd = &cobra.Command{
	Use:     "athanor",
	Short:   "Your athanor: show it and its settings",
	GroupID: "identity",
	Long: "An athanor is where things run: your own place, minted when your account is set up. " +
		"`cyfr athanor` alone shows yours, with its settings, which you change on CYFR's " +
		"Settings page. You talk with other people in threads, in CYFR's chat.",
	Args: cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		return showAthanor(cmd, nil)
	},
}

var athanorGetCmd = &cobra.Command{
	Use:     "get [athanor]",
	Short:   "Show an athanor (yours when omitted)",
	Args:    cobra.MaximumNArgs(1),
	Aliases: []string{"show"},
	RunE: func(cmd *cobra.Command, args []string) error {
		return showAthanor(cmd, args)
	},
}

// showAthanor prints the athanor args names, the caller's when none: its
// name, route and status, each setting it holds, and, while it is not
// provisioned, why and where to retry it.
func showAthanor(cmd *cobra.Command, args []string) error {
	payload := ops.AthanorGetArgs{}
	if len(args) == 1 {
		payload.Athanor = ops.Value(args[0])
	}
	result, err := newClient().CallTool(cmd.Context(), ops.Athanor, payload)
	if err != nil {
		return handleToolError(err)
	}
	if flagJSON {
		output.JSON(result)
		return nil
	}
	fmt.Printf("%s (%s) — %s\n", str(result["name"]), str(result["route"]), str(result["status"]))
	if settings, _ := result["settings"].(map[string]any); len(settings) > 0 {
		fmt.Println("  settings:")
		for _, line := range settingLines(settings) {
			fmt.Println("    " + line)
		}
	}
	if provisioned, _ := result["provisioned"].(bool); !provisioned {
		fmt.Println("  not provisioned yet: retry it from the Aqua panel in CYFR")
		if failure, _ := result["provisioning_failure"].(map[string]any); failure != nil {
			fmt.Printf("  the last attempt failed at %s: %s\n", str(failure["step"]), str(failure["detail"]))
		}
	}
	return nil
}

// settingLines is settings as key=value lines, one level deep, sorted by
// key.
func settingLines(settings map[string]any) []string {
	var lines []string
	for key, value := range settings {
		if nested, ok := value.(map[string]any); ok {
			for sub, v := range nested {
				lines = append(lines, fmt.Sprintf("%s.%s=%v", key, sub, v))
			}
			continue
		}
		lines = append(lines, fmt.Sprintf("%s=%v", key, value))
	}
	slices.Sort(lines)
	return lines
}
