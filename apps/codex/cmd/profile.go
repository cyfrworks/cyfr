// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"fmt"

	"github.com/cyfr/codex/internal/ops"
	"github.com/cyfr/codex/internal/output"
	"github.com/spf13/cobra"
)

func init() {

	profileCmd.AddCommand(profileListCmd)
	profileCmd.AddCommand(profileRevokeCmd)
	rootCmd.AddCommand(profileCmd)
}

var profileCmd = &cobra.Command{
	Use:     "profile",
	Short:   "List and revoke app profiles",
	GroupID: "security",
	Long: "A profile is a component you granted: which vault entries it may use, " +
		"what it may reach, recorded as an immutable consent revision. You grant " +
		"one in CYFR: on Components, open the component and choose Grant access.",
}

var profileListCmd = &cobra.Command{
	Use:   "list <reference>",
	Short: "List a component's profiles",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		client := newClient()

		result, err := client.CallTool(cmd.Context(), ops.Profile, ops.ProfileListArgs{Ref: args[0]})
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

			fmt.Printf("%-38s %-8s %-12s %s\n",
				str(p["id"]), str(p["kind"]), str(p["status"]), headLine(p))
		}
		return nil
	},
}

// headLine is how a listed profile's head reads: its revision when the
// home read it, and otherwise what stands in its place. A head that is
// damaged, or that the home could not read, is never shown as none, so an
// outage does not read as a grant to make.
func headLine(p map[string]any) string {
	switch p["head_state"] {
	case "present":
		if r, ok := p["head_revision"].(float64); ok {
			return fmt.Sprintf("consent rev %.0f", r)
		}
	case "missing":
		return "consent rev none"
	case "damaged":
		return "consent damaged"
	case "unavailable":
		return "consent unavailable — try again"
	}
	return "consent damaged"
}

var profileRevokeCmd = &cobra.Command{
	Use:   "revoke <profile-id>",
	Short: "Revoke a profile",
	Long:  "Revocation takes effect on the next run. Executions already running complete.",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		client := newClient()

		result, err := client.CallTool(cmd.Context(), ops.Profile, ops.ProfileRevokeArgs{ProfileId: args[0]})
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

// str is value as text, "" for none.
func str(value any) string {
	if value == nil {
		return ""
	}
	return fmt.Sprintf("%v", value)
}
