// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"fmt"
	"github.com/cyfr/codex/internal/ops"
	"slices"
	"strings"

	"github.com/cyfr/codex/internal/output"
	"github.com/spf13/cobra"
)

func init() {
	athanorSettingsCmd.Flags().StringArray("set", nil, "A setting to merge, as key=value or key.sub=value (repeatable); an empty value deletes the key")

	athanorCmd.AddCommand(athanorGetCmd)
	athanorCmd.AddCommand(athanorSettingsCmd)
	rootCmd.AddCommand(athanorCmd)
}

var athanorCmd = &cobra.Command{
	Use:     "athanor",
	Short:   "Your athanor: show it, merge its settings",
	GroupID: "identity",
	Long: "An athanor is where things run: your own place, minted when your account is set up. " +
		"`cyfr athanor` alone shows yours. You talk with other people in threads, in CYFR's chat.",
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
		fmt.Println("  not provisioned yet: retry it from the AQUA panel in CYFR")
		if failure, _ := result["provisioning_failure"].(map[string]any); failure != nil {
			fmt.Printf("  the last attempt failed at %s: %s\n", str(failure["step"]), str(failure["detail"]))
		}
	}
	return nil
}

// settingLines is settings as key=value lines, one level deep as
// `--set` writes them, sorted by key.
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

var athanorSettingsCmd = &cobra.Command{
	Use:   "settings [athanor] --set key=value [--set key.sub=value]",
	Short: "Merge settings into an athanor (e.g. --set aqua.answer_mode=all)",
	Long: "Settings merge one level deep: `--set aqua.answer_mode=all` changes that one key " +
		"under `aqua` and leaves the rest of `aqua` alone; `--set aqua.answer_mode=` deletes it.",
	Args: cobra.MaximumNArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		pairs, _ := cmd.Flags().GetStringArray("set")
		if len(pairs) == 0 {
			fmt.Fprintln(cmd.ErrOrStderr(), "Nothing to set: pass --set key=value. What the athanor holds now:")
			return showAthanor(cmd, args)
		}
		settings, err := parseSettings(pairs)
		if err != nil {
			fmt.Fprintln(cmd.ErrOrStderr(), err.Error())
			return nil
		}
		payload := ops.AthanorSettingsArgs{Settings: settings}
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
		fmt.Printf("Settings updated for %s\n", str(result["name"]))
		return nil
	},
}

// parseSettings turns `key=value` and `key.sub=value` pairs into the nested
// map `athanor.settings` merges; an empty value becomes nil, which deletes.
func parseSettings(pairs []string) (map[string]any, error) {
	settings := map[string]any{}
	for _, pair := range pairs {
		key, value, ok := strings.Cut(pair, "=")
		if !ok || key == "" {
			return nil, fmt.Errorf("--set expects key=value, got %q", pair)
		}
		var v any = value
		if value == "" {
			v = nil
		}
		if parent, sub, nested := strings.Cut(key, "."); nested {
			inner, _ := settings[parent].(map[string]any)
			if inner == nil {
				inner = map[string]any{}
			}
			inner[sub] = v
			settings[parent] = inner
		} else {
			settings[key] = v
		}
	}
	return settings, nil
}
