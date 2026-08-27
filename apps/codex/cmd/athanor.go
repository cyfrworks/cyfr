// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"fmt"
	"strings"

	"github.com/cyfr/codex/internal/output"
	"github.com/spf13/cobra"
)

func init() {
	athanorCreateCmd.Flags().String("slug", "", "Slug for the group (derived from the name when omitted)")
	athanorSettingsCmd.Flags().StringArray("set", nil, "A setting to merge, as key=value or key.sub=value (repeatable); an empty value deletes the key")

	athanorCmd.AddCommand(athanorListCmd)
	athanorCmd.AddCommand(athanorGetCmd)
	athanorCmd.AddCommand(athanorCreateCmd)
	athanorCmd.AddCommand(athanorRenameCmd)
	athanorCmd.AddCommand(athanorArchiveCmd)
	athanorCmd.AddCommand(athanorUnarchiveCmd)
	athanorCmd.AddCommand(athanorSettingsCmd)
	athanorCmd.AddCommand(athanorProvisionCmd)
	athanorCmd.AddCommand(athanorUseCmd)
	rootCmd.AddCommand(athanorCmd)
}

var athanorCmd = &cobra.Command{
	Use:     "athanor",
	Short:   "Your athanors: your own and your groups",
	GroupID: "identity",
	Long: "An athanor is where things run — yours, minted at sign-in, and every group " +
		"you belong to. `use` points this session at one of them; every other command " +
		"then works there.",
}

var athanorListCmd = &cobra.Command{
	Use:   "list",
	Short: "List the athanors you belong to",
	RunE: func(cmd *cobra.Command, args []string) error {
		result, err := newClient().CallTool(cmd.Context(), "athanor", map[string]any{"action": "list"})
		if err != nil {
			return handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
			return nil
		}
		athanors, _ := result["athanors"].([]any)
		for _, raw := range athanors {
			a, ok := raw.(map[string]any)
			if !ok {
				continue
			}
			fmt.Printf("%-40s %-7s %-20s %s\n", str(a["id"]), str(a["kind"]), str(a["route"]), str(a["name"]))
		}
		return nil
	},
}

var athanorGetCmd = &cobra.Command{
	Use:   "get [athanor]",
	Short: "Show an athanor (the one in focus when omitted)",
	Args:  cobra.MaximumNArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		payload := map[string]any{"action": "get"}
		if len(args) == 1 {
			payload["athanor"] = args[0]
		}
		result, err := newClient().CallTool(cmd.Context(), "athanor", payload)
		if err != nil {
			return handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
			return nil
		}
		fmt.Printf("%s (%s) — %s, %s, %d member(s)\n",
			str(result["name"]), str(result["route"]), str(result["kind"]), str(result["status"]),
			intOf(result["member_count"]))
		if result["provisioned_at"] == nil {
			fmt.Println("  not provisioned yet — `cyfr athanor provision` retries")
		}
		return nil
	},
}

var athanorCreateCmd = &cobra.Command{
	Use:   "create <name>",
	Short: "Create a group — you are its first member",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		payload := map[string]any{"action": "create", "name": args[0]}
		if slug, _ := cmd.Flags().GetString("slug"); slug != "" {
			payload["slug"] = slug
		}
		result, err := newClient().CallTool(cmd.Context(), "athanor", payload)
		if err != nil {
			return handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
			return nil
		}
		fmt.Printf("Created %s (%s) — `cyfr athanor use %s` to work there.\n",
			str(result["name"]), str(result["route"]), str(result["route"]))
		return nil
	},
}

var athanorRenameCmd = &cobra.Command{
	Use:   "rename <athanor> <name>",
	Short: "Rename an athanor (its slug stays)",
	Args:  cobra.ExactArgs(2),
	RunE: func(cmd *cobra.Command, args []string) error {
		result, err := newClient().CallTool(cmd.Context(), "athanor", map[string]any{
			"action": "rename", "athanor": args[0], "name": args[1],
		})
		if err != nil {
			return handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
			return nil
		}
		fmt.Printf("Renamed to %s\n", str(result["name"]))
		return nil
	},
}

var athanorArchiveCmd = &cobra.Command{
	Use:   "archive <athanor>",
	Short: "Archive a group (nothing is deleted; every ingress refuses it)",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		result, err := newClient().CallTool(cmd.Context(), "athanor", map[string]any{
			"action": "archive", "athanor": args[0],
		})
		if err != nil {
			return handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
			return nil
		}
		fmt.Printf("Archived %s\n", str(result["name"]))
		return nil
	},
}

var athanorUnarchiveCmd = &cobra.Command{
	Use:   "unarchive <athanor>",
	Short: "Reopen an archived group",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		result, err := newClient().CallTool(cmd.Context(), "athanor", map[string]any{
			"action": "unarchive", "athanor": args[0],
		})
		if err != nil {
			return handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
			return nil
		}
		fmt.Printf("Reopened %s\n", str(result["name"]))
		return nil
	},
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
			fmt.Fprintln(cmd.ErrOrStderr(), "nothing to set — pass at least one --set key=value")
			return nil
		}
		settings, err := parseSettings(pairs)
		if err != nil {
			fmt.Fprintln(cmd.ErrOrStderr(), err.Error())
			return nil
		}
		payload := map[string]any{"action": "settings", "settings": settings}
		if len(args) == 1 {
			payload["athanor"] = args[0]
		}
		result, err := newClient().CallTool(cmd.Context(), "athanor", payload)
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

var athanorProvisionCmd = &cobra.Command{
	Use:   "provision [athanor]",
	Short: "Retry a provisioning that failed (idempotent)",
	Args:  cobra.MaximumNArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		payload := map[string]any{"action": "provision"}
		if len(args) == 1 {
			payload["athanor"] = args[0]
		}
		result, err := newClient().CallTool(cmd.Context(), "athanor", payload)
		if err != nil {
			return handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
			return nil
		}
		fmt.Printf("Provisioned %s\n", str(result["name"]))
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

func intOf(v any) int {
	switch n := v.(type) {
	case float64:
		return int(n)
	case int:
		return n
	default:
		return 0
	}
}

var athanorUseCmd = &cobra.Command{
	Use:   "use <athanor>",
	Short: "Point this session at an athanor (an id, a group slug, or @namespace)",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		result, err := newClient().CallTool(cmd.Context(), "session", map[string]any{
			"action": "use", "athanor": args[0],
		})
		if err != nil {
			return handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
			return nil
		}
		athanor, _ := result["athanor"].(map[string]any)
		fmt.Printf("Now working in %s (%s)\n", str(athanor["name"]), str(athanor["route"]))
		return nil
	},
}
