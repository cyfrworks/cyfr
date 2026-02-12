package cmd

import (
	"fmt"
	"strings"

	"github.com/cyfr/codex/internal/output"
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
	Use:     "get <subject>",
	Short:   "Get permissions for a subject",
	Long:    "Show the permissions currently assigned to a subject.",
	Example: "  cyfr permission get user@example.com",
	Args:    cobra.ExactArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		client := newClient()
		result, err := client.CallTool("permission", map[string]any{
			"action":  "get",
			"subject": args[0],
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
	Use:   "set <subject> <permissions...>",
	Short: "Set permissions for a subject",
	Long:  "Replace the permission set for a subject. Permissions can be space or comma separated.",
	Example: `  cyfr permission set user@example.com read,write
  cyfr permission set pk_mykey execute`,
	Args: cobra.MinimumNArgs(2),
	Run: func(cmd *cobra.Command, args []string) {
		// Parse comma-separated or space-separated permissions
		var perms []string
		for _, a := range args[1:] {
			perms = append(perms, strings.Split(a, ",")...)
		}

		client := newClient()
		result, err := client.CallTool("permission", map[string]any{
			"action":      "set",
			"subject":     args[0],
			"permissions": perms,
		})
		if err != nil {
			output.Errorf("Failed: %v", err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			fmt.Printf("Permissions updated for '%s'.\n", args[0])
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
