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
	memberCmd.PersistentFlags().String("athanor", "", "The athanor (id, group slug, or @namespace); defaults to the one in focus")

	memberCmd.AddCommand(memberListCmd)
	memberCmd.AddCommand(memberAddCmd)
	memberCmd.AddCommand(memberRemoveCmd)
	memberCmd.AddCommand(memberLeaveCmd)
	rootCmd.AddCommand(memberCmd)
}

var memberCmd = &cobra.Command{
	Use:     "member",
	Short:   "Who is in an athanor",
	GroupID: "identity",
	Long: "Every member is the athanor's admin: anyone may add (by email or user id), " +
		"remove, or leave. Adding an email the server has not seen leaves an " +
		"invitation that activates on that person's first sign-in.",
}

func memberAthanor(cmd *cobra.Command) ops.Field[string] {
	if athanor, _ := cmd.Flags().GetString("athanor"); athanor != "" {
		return ops.Value(athanor)
	}
	return ops.Field[string]{}
}

var memberListCmd = &cobra.Command{
	Use:   "list",
	Short: "List the members",
	RunE: func(cmd *cobra.Command, args []string) error {
		result, err := newClient().CallTool(cmd.Context(), ops.Member, ops.MemberListArgs{Athanor: memberAthanor(cmd)})
		if err != nil {
			return handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
			return nil
		}
		members, _ := result["members"].([]any)
		for _, raw := range members {
			m, ok := raw.(map[string]any)
			if !ok {
				continue
			}
			who := str(m["display_name"])
			if who == "" {
				who = str(m["namespace"])
			}
			fmt.Printf("%-8s %-30s %s\n", str(m["status"]), str(m["email"]), who)
		}
		return nil
	},
}

var memberAddCmd = &cobra.Command{
	Use:   "add <email|user_id>",
	Short: "Add someone",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		payload := ops.MemberAddArgs{Athanor: memberAthanor(cmd)}
		if memberKey(args[0]) == "email" {
			payload.Email = ops.Value(args[0])
		} else {
			payload.UserId = ops.Value(args[0])
		}
		result, err := newClient().CallTool(cmd.Context(), ops.Member, payload)
		if err != nil {
			return handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
			return nil
		}
		fmt.Println("Added. If they have never signed in here, the seat waits for them.")
		return nil
	},
}

var memberRemoveCmd = &cobra.Command{
	Use:   "remove <email|user_id>",
	Short: "Remove someone",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		payload := ops.MemberRemoveArgs{Athanor: memberAthanor(cmd)}
		if memberKey(args[0]) == "email" {
			payload.Email = ops.Value(args[0])
		} else {
			payload.UserId = ops.Value(args[0])
		}
		result, err := newClient().CallTool(cmd.Context(), ops.Member, payload)
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

var memberLeaveCmd = &cobra.Command{
	Use:   "leave",
	Short: "Leave the group",
	RunE: func(cmd *cobra.Command, args []string) error {
		result, err := newClient().CallTool(cmd.Context(), ops.Member, ops.MemberLeaveArgs{Athanor: memberAthanor(cmd)})
		if err != nil {
			return handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
			return nil
		}
		fmt.Println("Left.")
		return nil
	},
}

// An `@` makes an email; anything else is an IdP subject.
func memberKey(target string) string {
	for _, c := range target {
		if c == '@' {
			return "email"
		}
	}
	return "user_id"
}
