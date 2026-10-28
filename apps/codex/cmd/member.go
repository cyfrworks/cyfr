// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"fmt"
	"regexp"

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
	Long: "Every member is the athanor's admin: anyone may add or remove someone, " +
		"named by user id (usr_…) or person identifier (per_…), or leave. Adding an " +
		"identifier the server has not seen leaves an invitation that activates on " +
		"that person's first sign-in here.",
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
	Use:   "add <user_id|identifier>",
	Short: "Add someone, by user id or person identifier (per_…)",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		result, err := newClient().CallTool(cmd.Context(), ops.Member, memberAddArgs(memberAthanor(cmd), args[0]))
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
	Use:   "remove <user_id|identifier>",
	Short: "Remove someone, or withdraw their invitation, by user id or person identifier (per_…)",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		result, err := newClient().CallTool(cmd.Context(), ops.Member, memberRemoveArgs(memberAthanor(cmd), args[0]))
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

// personIdentifier is the person identifier grammar Prima.Identity holds a
// `per_…` value to: `per_` and 64 lowercase hexadecimal digits.
var personIdentifier = regexp.MustCompile(`\Aper_[0-9a-f]{64}\z`)

// How an argument names a person: a person identifier by its grammar, and
// anything else a user id.
func memberKey(target string) string {
	if personIdentifier.MatchString(target) {
		return "identifier"
	}
	return "user_id"
}

// memberPerson is the one field an argument fills, by its key.
func memberPerson(target string) (userID, identifier ops.Field[string]) {
	if memberKey(target) == "identifier" {
		identifier = ops.Value(target)
	} else {
		userID = ops.Value(target)
	}
	return userID, identifier
}

func memberAddArgs(athanor ops.Field[string], target string) ops.MemberAddArgs {
	userID, identifier := memberPerson(target)
	return ops.MemberAddArgs{Athanor: athanor, UserId: userID, Identifier: identifier}
}

func memberRemoveArgs(athanor ops.Field[string], target string) ops.MemberRemoveArgs {
	userID, identifier := memberPerson(target)
	return ops.MemberRemoveArgs{Athanor: athanor, UserId: userID, Identifier: identifier}
}
