package cmd

import (
	"fmt"
	"os"
	"strings"

	"github.com/cyfr/codex/internal/output"
	"github.com/cyfr/codex/internal/prompt"
	"github.com/spf13/cobra"
)

func init() {
	rootCmd.AddCommand(permissionCmd)
	permissionCmd.AddCommand(permGetCmd)
	permissionCmd.AddCommand(permSetCmd)
	permissionCmd.AddCommand(permListCmd)
}

var permissionCmd = &cobra.Command{
	Use:     "permission",
	Short:   "Manage RBAC permissions",
	GroupID: "security",
	Long:    "View and assign role-based access control (RBAC) permissions to subjects such as users, API keys, or components.",
}

var permGetCmd = &cobra.Command{
	Use:     "get [subject]",
	Short:   "Get permissions for a subject",
	Long:    "Show the permissions currently assigned to a subject. Run without arguments for interactive selection.",
	Example: "  cyfr permission get user@example.com",
	Args:    cobra.RangeArgs(0, 1),
	Run: func(cmd *cobra.Command, args []string) {
		var subject string

		switch {
		case len(args) >= 1:
			subject = args[0]
		case prompt.IsInteractive(flagNoInteractive):
			client := newClient()
			opts, err := prompt.FetchPermissionSubjects(client)
			if err != nil {
				handleToolError(err)
			}
			if len(opts) == 0 {
				output.Error("No permission entries found. Set permissions with 'cyfr permission set'.")
			}
			selected, err := prompt.SelectOne("Select a subject", opts)
			if err != nil {
				if prompt.IsAborted(err) {
					os.Exit(130)
				}
				output.Errorf("Prompt failed: %v", err)
			}
			subject = selected
		default:
			output.Error("Usage: cyfr permission get <subject>")
		}

		client := newClient()
		result, err := client.CallTool("permission", map[string]any{
			"action":  "get",
			"subject": subject,
		})
		if err != nil {
			output.Errorf("Failed: %v", err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			output.KeyValue(result)
		}
	},
}

var permSetCmd = &cobra.Command{
	Use:   "set [subject] [permissions...]",
	Short: "Set permissions for a subject",
	Long:  "Replace the permission set for a subject. Permissions can be space or comma separated. Run without arguments for interactive selection.",
	Example: `  cyfr permission set user@example.com read,write
  cyfr permission set pk_mykey execute`,
	Args: cobra.MinimumNArgs(0),
	Run: func(cmd *cobra.Command, args []string) {
		var subject string
		var perms []string

		switch {
		case len(args) >= 2:
			// Direct mode (unchanged)
			subject = args[0]
			for _, a := range args[1:] {
				perms = append(perms, strings.Split(a, ",")...)
			}
		case prompt.IsInteractive(flagNoInteractive):
			client := newClient()

			// Select subject
			opts, err := prompt.FetchPermissionSubjects(client)
			if err != nil {
				handleToolError(err)
			}
			if len(opts) == 0 {
				// No existing subjects — ask for manual input
				subject, err = prompt.InputText("Enter subject (user, key, or component)", "user@example.com")
				if err != nil {
					if prompt.IsAborted(err) {
						os.Exit(130)
					}
					output.Errorf("Prompt failed: %v", err)
				}
			} else {
				subject, err = prompt.SelectOne("Select a subject", opts)
				if err != nil {
					if prompt.IsAborted(err) {
						os.Exit(130)
					}
					output.Errorf("Prompt failed: %v", err)
				}
			}

			// Multi-select permissions
			permOpts := []prompt.Option{
				{Label: "read", Value: "read"},
				{Label: "write", Value: "write"},
				{Label: "execute", Value: "execute"},
				{Label: "admin", Value: "admin"},
			}
			selected, err := prompt.SelectMany("Select permissions", permOpts)
			if err != nil {
				if prompt.IsAborted(err) {
					os.Exit(130)
				}
				output.Errorf("Prompt failed: %v", err)
			}
			if len(selected) == 0 {
				fmt.Println("No permissions selected.")
				return
			}
			perms = selected
		default:
			output.Error("Usage: cyfr permission set <subject> <permissions...>")
		}

		client := newClient()
		result, err := client.CallTool("permission", map[string]any{
			"action":      "set",
			"subject":     subject,
			"permissions": perms,
		})
		if err != nil {
			output.Errorf("Failed: %v", err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			fmt.Printf("Permissions updated for '%s'.\n", subject)
		}
		_ = result
	},
}

var permListCmd = &cobra.Command{
	Use:     "list",
	Short:   "List all permission entries",
	Long:    "List every subject and its assigned permissions.",
	Example: "  cyfr permission list",
	Run: func(cmd *cobra.Command, args []string) {
		client := newClient()
		result, err := client.CallTool("permission", map[string]any{
			"action": "list",
		})
		if err != nil {
			output.Errorf("Failed: %v", err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			output.KeyValue(result)
		}
	},
}
