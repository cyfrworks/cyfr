package cmd

import (
	"fmt"
	"strings"

	"github.com/cyfr/codex/internal/output"
	"github.com/spf13/cobra"
)

func init() {
	rootCmd.AddCommand(secretCmd)
	secretCmd.AddCommand(secretSetCmd)
	secretCmd.AddCommand(secretGetCmd)
	secretCmd.AddCommand(secretDeleteCmd)
	secretCmd.AddCommand(secretListCmd)
	secretCmd.AddCommand(secretGrantCmd)
	secretCmd.AddCommand(secretRevokeCmd)
}

var secretCmd = &cobra.Command{
	Use:     "secret",
	Short:   "Manage encrypted secrets",
	GroupID: "security",
	Long:    "Store, retrieve, and share secrets that are encrypted at rest with AES-256-GCM. Components must be explicitly granted access before they can read a secret.",
}

var secretSetCmd = &cobra.Command{
	Use:     "set <name>=<value>",
	Short:   "Store a secret",
	Long:    "Create or update an encrypted secret. The value is encrypted server-side before storage.",
	Example: `  cyfr secret set DATABASE_URL=postgres://localhost/mydb
  cyfr secret set API_KEY=sk-abc123`,
	Args: cobra.ExactArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		parts := strings.SplitN(args[0], "=", 2)
		if len(parts) != 2 {
			output.Error("Usage: cyfr secret set NAME=VALUE")
		}

		client := newClient()
		result, err := client.CallTool("secret", map[string]any{
			"action": "set",
			"name":   parts[0],
			"value":  parts[1],
		})
		if err != nil {
			output.Errorf("Failed: %v", err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			fmt.Printf("Secret '%s' stored.\n", parts[0])
		}
	},
}

var secretGetCmd = &cobra.Command{
	Use:     "get <name>",
	Short:   "Retrieve a secret (masked)",
	Long:    "Fetch a secret's metadata and masked value from the server.",
	Example: "  cyfr secret get DATABASE_URL",
	Args:    cobra.ExactArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		client := newClient()
		result, err := client.CallTool("secret", map[string]any{
			"action": "get",
			"name":   args[0],
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

var secretDeleteCmd = &cobra.Command{
	Use:     "delete <name>",
	Short:   "Delete a secret",
	Long:    "Permanently remove a secret and revoke all component grants.",
	Example: "  cyfr secret delete DATABASE_URL",
	Args:    cobra.ExactArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		client := newClient()
		result, err := client.CallTool("secret", map[string]any{
			"action": "delete",
			"name":   args[0],
		})
		if err != nil {
			output.Errorf("Failed: %v", err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			fmt.Printf("Secret '%s' deleted.\n", args[0])
		}
	},
}

var secretListCmd = &cobra.Command{
	Use:     "list",
	Short:   "List all secrets",
	Long:    "List all stored secret names and their metadata without revealing values.",
	Example: "  cyfr secret list",
	Run: func(cmd *cobra.Command, args []string) {
		client := newClient()
		result, err := client.CallTool("secret", map[string]any{
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

var secretGrantCmd = &cobra.Command{
	Use:     "grant <component> <name>",
	Short:   "Grant component access to a secret",
	Long:    "Allow a component to read the named secret at execution time.",
	Example: "  cyfr secret grant acme.sentiment:1.0.0 DATABASE_URL",
	Args:    cobra.ExactArgs(2),
	Run: func(cmd *cobra.Command, args []string) {
		component := normalizeComponentRef(args[0])
		client := newClient()
		result, err := client.CallTool("secret", map[string]any{
			"action":        "grant",
			"component_ref": component,
			"name":          args[1],
		})
		if err != nil {
			output.Errorf("Failed: %v", err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			fmt.Printf("Granted '%s' access to secret '%s'.\n", component, args[1])
		}
	},
}

var secretRevokeCmd = &cobra.Command{
	Use:     "revoke <component> <name>",
	Short:   "Revoke component access to a secret",
	Long:    "Remove a component's ability to read the named secret.",
	Example: "  cyfr secret revoke acme.sentiment:1.0.0 DATABASE_URL",
	Args:    cobra.ExactArgs(2),
	Run: func(cmd *cobra.Command, args []string) {
		component := normalizeComponentRef(args[0])
		client := newClient()
		result, err := client.CallTool("secret", map[string]any{
			"action":        "revoke",
			"component_ref": component,
			"name":          args[1],
		})
		if err != nil {
			output.Errorf("Failed: %v", err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			fmt.Printf("Revoked '%s' access to secret '%s'.\n", component, args[1])
		}
	},
}

