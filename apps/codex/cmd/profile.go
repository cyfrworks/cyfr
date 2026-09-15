// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"fmt"
	"github.com/cyfr/codex/internal/ops"
	"strings"

	"github.com/cyfr/codex/internal/output"
	"github.com/cyfr/codex/internal/prompt"
	"github.com/spf13/cobra"
)

func init() {
	profileGrantCmd.Flags().StringSlice("entry", nil,
		"Bind a need to a vault entry non-interactively: need=entry_id (repeatable)")

	profileCmd.AddCommand(profileGrantCmd)
	profileCmd.AddCommand(profileListCmd)
	profileCmd.AddCommand(profileRevokeCmd)
	rootCmd.AddCommand(profileCmd)
}

var profileCmd = &cobra.Command{
	Use:     "profile",
	Short:   "Grant, inspect and revoke app profiles",
	GroupID: "security",
	Long: "A profile is a component you granted: which vault entries it may use, " +
		"what it may reach, recorded as an immutable consent revision.\n\n" +
		"Nothing is granted outside this walk — plan shows what would be " +
		"granted, preview renders exactly what you are approving, and commit " +
		"records it.",
}

var profileListCmd = &cobra.Command{
	Use:   "list <reference>",
	Short: "List a component's profiles",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		client := newClient()

		result, err := client.CallTool(cmd.Context(), ops.Profile, map[string]any{
			"action": ops.ProfileList,
			"ref":    args[0],
		})
		if err != nil {
			return handleToolError(err)
		}

		if flagJSON {
			output.JSON(result)
			return nil
		}

		profiles, _ := result["profiles"].([]any)
		if len(profiles) == 0 {
			fmt.Println("No profiles — this component has never been granted.")
			return nil
		}

		for _, entry := range profiles {
			p, ok := entry.(map[string]any)
			if !ok {
				continue
			}

			rev := "none"
			if r, ok := p["head_revision"].(float64); ok {
				rev = fmt.Sprintf("%.0f", r)
			}

			fmt.Printf("%-38s %-8s %-12s consent rev %s\n",
				str(p["id"]), str(p["kind"]), str(p["status"]), rev)
		}
		return nil
	},
}

var profileRevokeCmd = &cobra.Command{
	Use:   "revoke <profile-id>",
	Short: "Revoke a profile",
	Long:  "Revocation takes effect on the next run. Executions already running complete.",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		client := newClient()

		result, err := client.CallTool(cmd.Context(), ops.Profile, map[string]any{
			"action":     ops.ProfileRevoke,
			"profile_id": args[0],
		})
		if err != nil {
			return handleToolError(err)
		}

		if flagJSON {
			output.JSON(result)
			return nil
		}

		output.Success(fmt.Sprintf("Revoked %s. Takes effect on the next run.", args[0]))
		return nil
	},
}

var profileGrantCmd = &cobra.Command{
	Use:   "grant <reference>",
	Short: "Grant a component the vault entries it needs [interactive]",
	Long: "Walks plan → preview → commit. You see what would be granted, pick " +
		"a vault entry for each need, then approve exactly what was rendered.",
	Example: `  cyfr profile grant c:moonmoon69.gmail
  cyfr profile grant f:local.daily-report --entry @ingress=vlt_abc123`,
	Args: cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		client := newClient()
		ref := args[0]

		plan, err := client.CallTool(cmd.Context(), ops.Profile, map[string]any{
			"action": ops.ProfilePlan,
			"ref":    ref,
		})
		if err != nil {
			return handleToolError(err)
		}

		bindings, err := collectBindings(cmd, plan)
		if err != nil {
			if prompt.IsAborted(err) {
				return prompt.ErrAborted
			}
			return err
		}

		decisions := map[string]any{"ref": ref, "bindings": bindings}

		preview, err := client.CallTool(cmd.Context(), ops.Profile, map[string]any{
			"action":    ops.ProfilePreview,
			"decisions": decisions,
		})
		if err != nil {
			return handleToolError(err)
		}

		renderPreview(preview)

		if !flagJSON && prompt.IsInteractive(flagNoInteractive) {
			ok, cerr := prompt.Confirm("Grant these permissions?")
			if cerr != nil || !ok {
				fmt.Println("Not granted.")
				return nil
			}
		}

		result, err := client.CallTool(cmd.Context(), ops.Profile, map[string]any{
			"action":                    ops.ProfileCommit,
			"decisions":                 decisions,
			"plan_token":                plan["plan_token"],
			"proof":                     preview["proof"],
			"commit_digest":             preview["commit_digest"],
			"expected_consent_revision": plan["expected_consent_revision"],
		})
		if err != nil {
			return handleToolError(err)
		}

		if flagJSON {
			output.JSON(result)
			return nil
		}

		output.Success(fmt.Sprintf("Granted. Consent rev %s.", str(result["revision"])))
		return nil
	},
}

// One vault entry per need: from --entry need=entry_id flags, or asked for
// interactively. A need left unbound
// is a deliberate choice — an app can be granted with no credentials at all.
func collectBindings(cmd *cobra.Command, plan map[string]any) ([]map[string]any, error) {
	preset := map[string]string{}

	flags, _ := cmd.Flags().GetStringSlice("entry")
	for _, pair := range flags {
		parts := strings.SplitN(pair, "=", 2)
		if len(parts) != 2 {
			return nil, fmt.Errorf("--entry expects need=entry_id, got %q", pair)
		}
		preset[parts[0]] = parts[1]
	}

	needs, _ := plan["needs"].([]any)
	candidates, _ := plan["candidates"].([]any)
	bindings := []map[string]any{}

	for _, entry := range needs {
		need, ok := entry.(map[string]any)
		if !ok {
			continue
		}

		name := str(need["need"])

		if entryID, given := preset[name]; given {
			bindings = append(bindings, map[string]any{"need": name, "entry_id": entryID})
			continue
		}

		if flagJSON || !prompt.IsInteractive(flagNoInteractive) {
			continue
		}

		entryID, err := askForEntry(need, candidates)
		if err != nil {
			return nil, err
		}
		if entryID != "" {
			bindings = append(bindings, map[string]any{"need": name, "entry_id": entryID})
		}
	}

	return bindings, nil
}

func askForEntry(need map[string]any, candidates []any) (string, error) {
	if len(candidates) == 0 {
		fmt.Println("No vault entries yet — create one first, or grant without one.")
		return "", nil
	}

	options := []prompt.Option{{Label: "No entry", Value: ""}}
	for _, entry := range candidates {
		c, ok := entry.(map[string]any)
		if !ok {
			continue
		}

		label := str(c["name"])
		if fields := joinStrings(c["field_names"]); fields != "" {
			label = fmt.Sprintf("%s (gets: %s)", label, fields)
		}

		options = append(options, prompt.Option{Label: label, Value: str(c["id"])})
	}

	title := str(need["reason"])
	if title == "" {
		title = fmt.Sprintf("Vault entry for %s", str(need["need"]))
	}

	return prompt.SelectOne(title, options)
}

func renderPreview(preview map[string]any) {
	if flagJSON {
		return
	}

	fmt.Println("You are approving:")

	summary, _ := preview["summary"].([]any)
	for _, line := range summary {
		fmt.Printf("  %s\n", str(line))
	}

	fmt.Print("\n  Vault entries are sealed at rest; a component receives only the fields listed.\n\n")
}

func str(value any) string {
	if value == nil {
		return ""
	}
	return fmt.Sprintf("%v", value)
}

func joinStrings(value any) string {
	list, ok := value.([]any)
	if !ok {
		return ""
	}

	parts := make([]string, 0, len(list))
	for _, item := range list {
		parts = append(parts, str(item))
	}

	return strings.Join(parts, ", ")
}
