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
	threadCmd.AddCommand(threadListCmd)
	threadCmd.AddCommand(threadCreateCmd)
	threadCmd.AddCommand(threadPairCmd)
	threadCmd.AddCommand(threadPeopleCmd)
	threadCmd.AddCommand(threadAddCmd)
	threadCmd.AddCommand(threadRemoveCmd)
	threadCmd.AddCommand(threadLeaveCmd)
	threadCmd.AddCommand(threadPostCmd)
	rootCmd.AddCommand(threadCmd)
}

var threadCmd = &cobra.Command{
	Use:     "thread",
	Short:   "Threads you talk in with other people",
	GroupID: "identity",
	Long: "A thread is a conversation you share with other people; it is no athanor's. " +
		"Anyone in a thread may add someone, named by user id (usr_…) or person " +
		"identifier (per_…), remove someone, or leave. Adding an identifier the server " +
		"has not seen leaves an invitation that activates on that person's first sign-in " +
		"here. Someone is also added by their name (@name): cyfr.run is asked which " +
		"identifier the name belongs to, and that identifier is added.",
}

var threadListCmd = &cobra.Command{
	Use:   "list",
	Short: "List the threads you are in",
	RunE: func(cmd *cobra.Command, args []string) error {
		result, err := newClient().CallTool(cmd.Context(), ops.SharedThread, ops.SharedThreadListArgs{})
		if err != nil {
			return handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
			return nil
		}
		threads, _ := result["threads"].([]any)
		for _, raw := range threads {
			t, ok := raw.(map[string]any)
			if !ok {
				continue
			}
			fmt.Printf("%-40s %-8s %s\n", str(t["id"]), str(t["status"]), threadTitle(t))
		}
		return nil
	},
}

var threadCreateCmd = &cobra.Command{
	Use:   "create <title>",
	Short: "Start a thread — you are its first person",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		result, err := newClient().CallTool(cmd.Context(), ops.SharedThread, ops.SharedThreadCreateArgs{Title: args[0]})
		if err != nil {
			return handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
			return nil
		}
		fmt.Printf("Started %s (%s) — `cyfr thread add %s @name` brings someone in.\n",
			str(result["title"]), str(result["id"]), str(result["id"]))
		return nil
	},
}

var threadPairCmd = &cobra.Command{
	Use:   "pair <user_id>",
	Short: "Open the thread of just you and one person you already share a thread with",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		result, err := newClient().CallTool(cmd.Context(), ops.SharedThread, ops.SharedThreadPairArgs{User: args[0]})
		if err != nil {
			return handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
			return nil
		}
		fmt.Printf("%s (%s)\n", threadTitle(result), str(result["id"]))
		return nil
	},
}

var threadPeopleCmd = &cobra.Command{
	Use:   "people <thread>",
	Short: "List the people in a thread and the invitations waiting",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		result, err := newClient().CallTool(cmd.Context(), ops.SharedThread, ops.SharedThreadPeopleArgs{Thread: args[0]})
		if err != nil {
			return handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
			return nil
		}
		people, _ := result["people"].([]any)
		for _, raw := range people {
			p, ok := raw.(map[string]any)
			if !ok {
				continue
			}
			who := str(p["name"])
			if handle := str(p["handle"]); handle != "" {
				who = strings.TrimSpace(who + " @" + handle)
			}
			id := str(p["user_id"])
			if id == "" {
				id = str(p["identifier"])
			}
			fmt.Printf("%-8s %-40s %s\n", str(p["status"]), id, who)
		}
		return nil
	},
}

var threadAddCmd = &cobra.Command{
	Use:   "add <thread> <@name|identifier|user_id>",
	Short: "Add someone, by name (@name), person identifier (per_…) or user id.",
	Args:  cobra.ExactArgs(2),
	RunE: func(cmd *cobra.Command, args []string) error {
		result, err := newClient().CallTool(cmd.Context(), ops.SharedThread, threadAddArgs(args[0], args[1]))
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

var threadRemoveCmd = &cobra.Command{
	Use:   "remove <thread> <user_id|identifier>",
	Short: "Remove someone, by user id or person identifier (per_…)",
	Args:  cobra.ExactArgs(2),
	RunE: func(cmd *cobra.Command, args []string) error {
		if personKey(args[1]) == "handle" {
			return errors.New("remove names someone by user id or person identifier; `cyfr thread people` shows both")
		}
		result, err := newClient().CallTool(cmd.Context(), ops.SharedThread, threadRemoveArgs(args[0], args[1]))
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

var threadLeaveCmd = &cobra.Command{
	Use:   "leave <thread>",
	Short: "Leave a thread",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		result, err := newClient().CallTool(cmd.Context(), ops.SharedThread, ops.SharedThreadLeaveArgs{Thread: args[0]})
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

var threadPostCmd = &cobra.Command{
	Use:   "post <thread> <words>",
	Short: "Say something in a thread",
	Args:  cobra.ExactArgs(2),
	RunE: func(cmd *cobra.Command, args []string) error {
		result, err := newClient().CallTool(cmd.Context(), ops.SharedThread, ops.SharedThreadPostArgs{Thread: args[0], Content: args[1]})
		if err != nil {
			return handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
			return nil
		}
		fmt.Println("Posted.")
		return nil
	},
}

// threadTitle is what a thread is called: its title, or for a pair the
// other person's name.
func threadTitle(t map[string]any) string {
	if title := str(t["title"]); title != "" {
		return title
	}
	with, _ := t["with"].(map[string]any)
	if name := str(with["name"]); name != "" {
		return "with " + name
	}
	return "with " + str(with["user_id"])
}

// personIdentifier is the person identifier grammar Prima.Identity holds a
// `per_…` value to: `per_` and 64 lowercase hexadecimal digits.
var personIdentifier = regexp.MustCompile(`\Aper_[0-9a-f]{64}\z`)

// How an argument names a person: a handle by its leading @, a person
// identifier by its grammar, and anything else a user id. The handle is
// sent as typed; the server reads its spelling and asks the registry.
func personKey(target string) string {
	switch {
	case strings.HasPrefix(target, "@"):
		return "handle"
	case personIdentifier.MatchString(target):
		return "identifier"
	default:
		return "user_id"
	}
}

// personFields is the one field an argument fills, by its key.
func personFields(target string) (userID, identifier, handle ops.Field[string]) {
	switch personKey(target) {
	case "handle":
		handle = ops.Value(target)
	case "identifier":
		identifier = ops.Value(target)
	default:
		userID = ops.Value(target)
	}
	return userID, identifier, handle
}

func threadAddArgs(thread, target string) ops.SharedThreadAddArgs {
	userID, identifier, handle := personFields(target)
	return ops.SharedThreadAddArgs{Thread: thread, UserId: userID, Identifier: identifier, Handle: handle}
}

// A removal names someone this server holds a row for, so it takes no
// handle; the command refuses one before this is built.
func threadRemoveArgs(thread, target string) ops.SharedThreadRemoveArgs {
	userID, identifier, _ := personFields(target)
	return ops.SharedThreadRemoveArgs{Thread: thread, UserId: userID, Identifier: identifier}
}
