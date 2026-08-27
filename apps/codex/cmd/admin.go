// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"errors"
	"fmt"

	"github.com/cyfr/codex/internal/output"
	"github.com/spf13/cobra"
)

func init() {
	adminAllowCmd.Flags().String("note", "", "Why (kept with the entry)")
	adminDenyCmd.Flags().String("note", "", "Why (kept with the entry)")
	adminResolveCmd.Flags().Bool("allow", false, "Approve the request")
	adminResolveCmd.Flags().Bool("reject", false, "Drop the request")

	adminCmd.AddCommand(adminListCmd)
	adminCmd.AddCommand(adminRequestsCmd)
	adminCmd.AddCommand(adminAllowCmd)
	adminCmd.AddCommand(adminDenyCmd)
	adminCmd.AddCommand(adminRemoveCmd)
	adminCmd.AddCommand(adminResolveCmd)
	rootCmd.AddCommand(adminCmd)
}

var adminCmd = &cobra.Command{
	Use:     "admin",
	Short:   "The door: who may sign in to this server (platform admins)",
	GroupID: "admin",
	Long: "The server allowlist is the door. Entries name an email, an IdP subject, " +
		"or `*` for anyone the configured provider authenticates. A deny is sticky " +
		"and ejects the person; requests are invites members made for addresses " +
		"the door does not know. Platform admins (CYFR_PLATFORM_ADMIN_EMAILS) " +
		"are always let in and are the only ones who may edit the list.",
}

var adminListCmd = &cobra.Command{
	Use:   "list",
	Short: "Show the door",
	RunE: func(cmd *cobra.Command, args []string) error {
		result, err := newClient().CallTool(cmd.Context(), "door", map[string]any{"action": "list"})
		if err != nil {
			return handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
			return nil
		}
		entries, _ := result["entries"].([]any)
		if len(entries) == 0 {
			fmt.Println("The door is empty — only the platform admins can sign in.")
			return nil
		}
		for _, raw := range entries {
			e, ok := raw.(map[string]any)
			if !ok {
				continue
			}
			fmt.Printf("%-38s %-8s %-6s %-9s %s\n",
				str(e["id"]), str(e["kind"]), str(e["effect"]), str(e["status"]), str(e["value"]))
		}
		return nil
	},
}

var adminRequestsCmd = &cobra.Command{
	Use:   "requests",
	Short: "Pending invites for addresses the door does not know",
	RunE: func(cmd *cobra.Command, args []string) error {
		result, err := newClient().CallTool(cmd.Context(), "door", map[string]any{"action": "requests"})
		if err != nil {
			return handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
			return nil
		}
		requests, _ := result["requests"].([]any)
		if len(requests) == 0 {
			fmt.Println("No pending requests.")
			return nil
		}
		for _, raw := range requests {
			r, ok := raw.(map[string]any)
			if !ok {
				continue
			}
			fmt.Printf("%-38s %-30s asked by %s\n", str(r["id"]), str(r["value"]), str(r["requested_by"]))
		}
		return nil
	},
}

var adminAllowCmd = &cobra.Command{
	Use:   "allow <email|user_id|*>",
	Short: "Let an identity sign in",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		note, _ := cmd.Flags().GetString("note")
		result, err := newClient().CallTool(cmd.Context(), "door", map[string]any{
			"action": "allow", "value": args[0], "note": note,
		})
		if err != nil {
			return handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
			return nil
		}
		fmt.Printf("Allowed %s\n", str(result["value"]))
		return nil
	},
}

var adminDenyCmd = &cobra.Command{
	Use:   "deny <email|user_id>",
	Short: "Keep an identity out — and eject them if they are here",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		note, _ := cmd.Flags().GetString("note")
		result, err := newClient().CallTool(cmd.Context(), "door", map[string]any{
			"action": "deny", "value": args[0], "note": note,
		})
		if err != nil {
			return handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
			return nil
		}
		fmt.Printf("Denied %s (%v ejected)\n", str(result["value"]), result["ejected"])
		return nil
	},
}

var adminRemoveCmd = &cobra.Command{
	Use:   "remove <entry-id>",
	Short: "Delete an entry",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		result, err := newClient().CallTool(cmd.Context(), "door", map[string]any{"action": "remove", "id": args[0]})
		if err != nil {
			return handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
			return nil
		}
		fmt.Println("Removed.")
		return nil
	},
}

var adminResolveCmd = &cobra.Command{
	Use:   "resolve <request-id> (--allow | --reject)",
	Short: "Approve or drop a pending request",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		allow, _ := cmd.Flags().GetBool("allow")
		reject, _ := cmd.Flags().GetBool("reject")
		if allow == reject {
			return errors.New("pass exactly one of --allow or --reject")
		}
		decision := "reject"
		if allow {
			decision = "allow"
		}
		result, err := newClient().CallTool(cmd.Context(), "door", map[string]any{
			"action": "resolve", "id": args[0], "decision": decision,
		})
		if err != nil {
			return handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
			return nil
		}
		fmt.Printf("Request %s: %s\n", args[0], decision)
		return nil
	},
}
