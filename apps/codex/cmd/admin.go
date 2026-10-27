// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"errors"
	"fmt"
	"github.com/cyfr/codex/internal/ops"

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
	Short:   "The sign-in allowlist: who may sign in to this server (platform admins)",
	GroupID: "admin",
	Long: "The server allowlist says who may sign in. A person made here signs in unless " +
		"a deny names them. A person who signs in with their CYFR identity from elsewhere " +
		"is let in by an allow naming their person identifier (per_…), or by `*`, which " +
		"lets anyone in, and lets anyone create an identity here. A deny names a person " +
		"here by their id (usr_…) or a person identifier; it is sticky and ejects the " +
		"person. Requests are invites members made for identifiers the allowlist does " +
		"not know, and sign-ins it refused. Only platform admins may edit the list, and " +
		"no deny names one.",
}

var adminListCmd = &cobra.Command{
	Use:   "list",
	Short: "Show the allowlist",
	RunE: func(cmd *cobra.Command, args []string) error {
		result, err := newClient().CallTool(cmd.Context(), ops.Door, ops.DoorListArgs{})
		if err != nil {
			return handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
			return nil
		}
		entries, _ := result["entries"].([]any)
		if len(entries) == 0 {
			fmt.Println("The allowlist is empty: the people made here sign in, and no one from elsewhere.")
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
	Short: "Pending invites for person identifiers (per_…) the allowlist does not know, and refused sign-ins",
	RunE: func(cmd *cobra.Command, args []string) error {
		result, err := newClient().CallTool(cmd.Context(), ops.Door, ops.DoorRequestsArgs{})
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
	Use:   "allow <identifier|*>",
	Short: "Let a person from elsewhere sign in, by person identifier (per_…), or * for anyone",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		note, _ := cmd.Flags().GetString("note")
		result, err := newClient().CallTool(cmd.Context(), ops.Door, ops.DoorAllowArgs{Value: args[0],
			Note: ops.Nullable(note)})
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
	Use:   "deny <person|identifier>",
	Short: "Keep a person out, by their id here (usr_…) or person identifier (per_…), and eject them if they are here",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		note, _ := cmd.Flags().GetString("note")
		result, err := newClient().CallTool(cmd.Context(), ops.Door, ops.DoorDenyArgs{Value: args[0],
			Note: ops.Nullable(note)})
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
		result, err := newClient().CallTool(cmd.Context(), ops.Door, ops.DoorRemoveArgs{Id: args[0]})
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
		result, err := newClient().CallTool(cmd.Context(), ops.Door, ops.DoorResolveArgs{Id: args[0],
			Decision: decision})
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
