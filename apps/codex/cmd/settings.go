// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"errors"
	"fmt"
	"math"
	"strconv"
	"strings"

	"github.com/cyfr/codex/internal/ops"
	"github.com/cyfr/codex/internal/output"
	"github.com/spf13/cobra"
)

func init() {
	for _, c := range []*cobra.Command{settingsSetCmd, settingsResetCmd} {
		c.Flags().Int("revision", 0, "The store revision `cyfr settings list` answered; a change made since refuses this one")
	}

	settingsCmd.AddCommand(settingsListCmd)
	settingsCmd.AddCommand(settingsSetCmd)
	settingsCmd.AddCommand(settingsResetCmd)
	rootCmd.AddCommand(settingsCmd)
}

var settingsCmd = &cobra.Command{
	Use:     "settings",
	Short:   "The platform settings: limits, windows and the log level (platform admins)",
	GroupID: "admin",
	Long: "The platform settings are the server's own: every member of a cell reads the same " +
		"stored value. A live change reaches new and refreshed work on every member within " +
		"the settings cache's bound, not work already in flight; a restart setting applies " +
		"at each member's next start and is listed as pending until then. A setting the " +
		"deployment's environment pins cannot be changed here.",
}

var settingsListCmd = &cobra.Command{
	Use:     "list",
	Short:   "Show every platform setting, its value and where it comes from",
	Example: "  cyfr settings list",
	RunE: func(cmd *cobra.Command, args []string) error {
		result, err := newClient().CallTool(cmd.Context(), ops.Settings, ops.SettingsListArgs{})
		if err != nil {
			return handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
			return nil
		}
		for _, line := range settingsLines(result) {
			fmt.Println(line)
		}
		return nil
	},
}

var settingsSetCmd = &cobra.Command{
	Use:   "set KEY VALUE",
	Short: "Set a platform setting",
	Args:  cobra.ExactArgs(2),
	Example: `  cyfr settings set mcp_rate_limit_max 240
  cyfr settings set log_level debug --revision 12`,
	RunE: func(cmd *cobra.Command, args []string) error {
		revision, err := settingsRevision(cmd)
		if err != nil {
			return err
		}
		result, err := newClient().CallTool(cmd.Context(), ops.Settings,
			ops.SettingsSetArgs{Key: args[0], Value: args[1], Revision: revision})
		if err != nil {
			return handleToolError(err)
		}
		return renderResult(result)
	},
}

var settingsResetCmd = &cobra.Command{
	Use:     "reset KEY",
	Short:   "Remove a platform setting's stored value, so its default applies",
	Args:    cobra.ExactArgs(1),
	Example: "  cyfr settings reset log_level",
	RunE: func(cmd *cobra.Command, args []string) error {
		revision, err := settingsRevision(cmd)
		if err != nil {
			return err
		}
		result, err := newClient().CallTool(cmd.Context(), ops.Settings,
			ops.SettingsResetArgs{Key: args[0], Revision: revision})
		if err != nil {
			return handleToolError(err)
		}
		return renderResult(result)
	},
}

// settingsRevision is the --revision a change is made against: absent
// unless the flag was given, so the server reads the current revision.
func settingsRevision(cmd *cobra.Command) (ops.Field[int], error) {
	if !cmd.Flags().Changed("revision") {
		return ops.Field[int]{}, nil
	}
	revision, _ := cmd.Flags().GetInt("revision")
	if revision < 0 {
		return ops.Field[int]{}, errors.New("--revision is a store revision, zero or more")
	}
	return ops.Value(revision), nil
}

// settingsLines renders a settings.list result: the desired store revision
// and what each member last observed, then one line per setting with its
// value, its source and, for a restart setting, the value pending.
func settingsLines(result map[string]any) []string {
	lines := []string{fmt.Sprintf("Store revision %s", settingText(result["revision"]))}

	members, _ := result["members"].([]any)
	for _, raw := range members {
		m, ok := raw.(map[string]any)
		if !ok {
			continue
		}
		observed := "unknown"
		if m["revision"] != nil {
			observed = settingText(m["revision"])
		}
		lines = append(lines, fmt.Sprintf("  %s observed %s", str(m["member"]), observed))
	}

	settings, _ := result["settings"].([]any)
	for _, raw := range settings {
		s, ok := raw.(map[string]any)
		if !ok {
			continue
		}
		line := fmt.Sprintf("%-36s %-20s %s", str(s["key"]), settingText(s["value"]), str(s["source"]))
		if pending, _ := s["pending"].(bool); pending {
			line += " (pending " + settingText(s["desired"]) + ")"
		}
		if divergent, _ := s["divergent"].(bool); divergent {
			line += " (pinned on some members only)"
		}
		lines = append(lines, strings.TrimRight(line, " "))
	}
	return lines
}

// settingText renders a JSON value as the setting's variable spells it: a
// whole number without an exponent, and an unset value as none.
func settingText(value any) string {
	switch v := value.(type) {
	case nil:
		return "none"
	case float64:
		if v == math.Trunc(v) && math.Abs(v) < 1<<53 {
			return strconv.FormatInt(int64(v), 10)
		}
		return strconv.FormatFloat(v, 'g', -1, 64)
	default:
		return str(v)
	}
}
