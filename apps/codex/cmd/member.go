// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"errors"
	"fmt"
	"regexp"
	"strings"

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
		"that person's first sign-in here. Someone is also added by their handle " +
		"(@name): the registry is asked which identifier it names, and that " +
		"identifier is added.",
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
	Use:   "add <user_id|identifier|@handle>",
	Short: "Add someone, by user id, person identifier (per_…) or handle (@name)",
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
		if memberKey(args[0]) == "handle" {
			return errors.New("remove names someone by user id or person identifier; `cyfr member list` shows both")
		}
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

// How an argument names a person: a handle by its leading @, a person
// identifier by its grammar, and anything else a user id. The handle is
// sent as typed; the server reads its spelling and asks the registry.
func memberKey(target string) string {
	switch {
	case strings.HasPrefix(target, "@"):
		return "handle"
	case personIdentifier.MatchString(target):
		return "identifier"
	default:
		return "user_id"
	}
}

// memberPerson is the one field an argument fills, by its key.
func memberPerson(target string) (userID, identifier, handle ops.Field[string]) {
	switch memberKey(target) {
	case "handle":
		handle = ops.Value(target)
	case "identifier":
		identifier = ops.Value(target)
	default:
		userID = ops.Value(target)
	}
	return userID, identifier, handle
}

func memberAddArgs(athanor ops.Field[string], target string) ops.MemberAddArgs {
	userID, identifier, handle := memberPerson(target)
	return ops.MemberAddArgs{Athanor: athanor, UserId: userID, Identifier: identifier, Handle: handle}
}

// A removal names someone this server holds a row for, so it takes no
// handle; the command refuses one before this is built.
func memberRemoveArgs(athanor ops.Field[string], target string) ops.MemberRemoveArgs {
	userID, identifier, _ := memberPerson(target)
	return ops.MemberRemoveArgs{Athanor: athanor, UserId: userID, Identifier: identifier}
}
