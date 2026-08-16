package cmd

import (
	"fmt"

	"github.com/cyfr/codex/internal/output"
	"github.com/spf13/cobra"
)

func init() {
	athanorCreateCmd.Flags().String("slug", "", "Slug for the group (derived from the name when omitted)")

	athanorCmd.AddCommand(athanorListCmd)
	athanorCmd.AddCommand(athanorCreateCmd)
	athanorCmd.AddCommand(athanorRenameCmd)
	athanorCmd.AddCommand(athanorArchiveCmd)
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
	Run: func(cmd *cobra.Command, args []string) {
		result, err := newClient().CallTool("athanor", map[string]any{"action": "list"})
		if err != nil {
			handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
			return
		}
		athanors, _ := result["athanors"].([]any)
		for _, raw := range athanors {
			a, ok := raw.(map[string]any)
			if !ok {
				continue
			}
			fmt.Printf("%-40s %-7s %-20s %s\n", str(a["id"]), str(a["kind"]), str(a["route"]), str(a["name"]))
		}
	},
}

var athanorCreateCmd = &cobra.Command{
	Use:   "create <name>",
	Short: "Create a group — you are its first member",
	Args:  cobra.ExactArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		payload := map[string]any{"action": "create", "name": args[0]}
		if slug, _ := cmd.Flags().GetString("slug"); slug != "" {
			payload["slug"] = slug
		}
		result, err := newClient().CallTool("athanor", payload)
		if err != nil {
			handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
			return
		}
		fmt.Printf("Created %s (%s) — `cyfr athanor use %s` to work there.\n",
			str(result["name"]), str(result["route"]), str(result["route"]))
	},
}

var athanorRenameCmd = &cobra.Command{
	Use:   "rename <athanor> <name>",
	Short: "Rename an athanor (its slug stays)",
	Args:  cobra.ExactArgs(2),
	Run: func(cmd *cobra.Command, args []string) {
		result, err := newClient().CallTool("athanor", map[string]any{
			"action": "rename", "athanor": args[0], "name": args[1],
		})
		if err != nil {
			handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
			return
		}
		fmt.Printf("Renamed to %s\n", str(result["name"]))
	},
}

var athanorArchiveCmd = &cobra.Command{
	Use:   "archive <athanor>",
	Short: "Archive a group (nothing is deleted; every ingress refuses it)",
	Args:  cobra.ExactArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		result, err := newClient().CallTool("athanor", map[string]any{
			"action": "archive", "athanor": args[0],
		})
		if err != nil {
			handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
			return
		}
		fmt.Printf("Archived %s\n", str(result["name"]))
	},
}

var athanorUseCmd = &cobra.Command{
	Use:   "use <athanor>",
	Short: "Point this session at an athanor (an id, a group slug, or @namespace)",
	Args:  cobra.ExactArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		result, err := newClient().CallTool("session", map[string]any{
			"action": "use", "athanor": args[0],
		})
		if err != nil {
			handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
			return
		}
		athanor, _ := result["athanor"].(map[string]any)
		fmt.Printf("Now working in %s (%s)\n", str(athanor["name"]), str(athanor["route"]))
	},
}
