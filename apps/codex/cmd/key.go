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
	rootCmd.AddCommand(keyCmd)
	keyCmd.AddCommand(keyCreateCmd)
	keyCmd.AddCommand(keyGetCmd)
	keyCmd.AddCommand(keyListCmd)
	keyCmd.AddCommand(keyRevokeCmd)
	keyCmd.AddCommand(keyRotateCmd)

	keyCreateCmd.Flags().String("name", "", "Key name (required in non-interactive mode)")
	keyCreateCmd.Flags().String("type", "application", "Key type: application, service, admin")
	keyCreateCmd.Flags().StringSlice("scope", nil, "Permission scopes (execute, secrets_read, secrets_write, component_read, component_manage, policy_read, policy_manage, storage_read, storage_write, users_read, users_manage, execution_write, admin)")
	keyCreateCmd.Flags().String("rate-limit", "", "Rate limit (e.g., '100/1m')")
	keyCreateCmd.Flags().StringSlice("ip-allowlist", nil, "Allowed IPs/CIDRs")
}

var keyCmd = &cobra.Command{
	Use:     "key",
	Short:   "Manage API keys",
	GroupID: "security",
	Long:    "Create, list, rotate, and revoke API keys. Key prefixes indicate type: pk_ (application), sk_ (service), ak_ (admin).",
}

var keyCreateCmd = &cobra.Command{
	Use:   "create",
	Short: "Create a new API key",
	Long: `Generate a new API key with the given name, type, and optional scopes, rate limit, and IP allowlist.
Run without --name for an interactive form.

Default scopes per type (applied when --scope is omitted):
  application: execute, component_read, policy_read, storage_read
  service:     execute, secrets_read, component_read, policy_read, storage_read, storage_write
  admin:       * (all permissions)`,
	Example: `  cyfr key create --name my-service --type service
  cyfr key create --name ci-runner --type application --scope execute,component_read
  cyfr key create --name prod --type admin --rate-limit 100/1m --ip-allowlist 10.0.0.0/8`,
	Run: func(cmd *cobra.Command, args []string) {
		name, _ := cmd.Flags().GetString("name")
		keyType, _ := cmd.Flags().GetString("type")
		scope, _ := cmd.Flags().GetStringSlice("scope")
		rateLimit, _ := cmd.Flags().GetString("rate-limit")
		ipAllowlist, _ := cmd.Flags().GetStringSlice("ip-allowlist")

		// If --name not provided, try interactive mode
		if name == "" {
			if !prompt.IsInteractive(flagNoInteractive) {
				output.Error("--name is required. Usage: cyfr key create --name <name>")
			}

			form, err := prompt.RunKeyCreateForm()
			if err != nil {
				if prompt.IsAborted(err) {
					os.Exit(130)
				}
				output.Errorf("Prompt failed: %v", err)
			}
			name = form.Name
			keyType = form.Type
			if len(form.Scopes) > 0 {
				scope = form.Scopes
			}
			if form.RateLimit != "" {
				rateLimit = form.RateLimit
			}
			if form.IPAllowlist != "" {
				ipAllowlist = strings.Split(form.IPAllowlist, ",")
			}
		}

		toolArgs := map[string]any{
			"action": "create",
			"name":   name,
			"type":   keyType,
		}
		if len(scope) > 0 {
			toolArgs["scope"] = scope
		}
		if rateLimit != "" {
			toolArgs["rate_limit"] = rateLimit
		}
		if len(ipAllowlist) > 0 {
			toolArgs["ip_allowlist"] = ipAllowlist
		}

		client := newClient()
		result, err := client.CallTool("key", toolArgs)
		if err != nil {
			handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			output.KeyValue(result)
		}
	},
}

var keyGetCmd = &cobra.Command{
	Use:     "get <name>",
	Short:   "Get key info",
	Long:    "Show metadata for an API key including type, scopes, and rate limits.",
	Example: "  cyfr key get my-service",
	Args:    cobra.ExactArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		client := newClient()
		result, err := client.CallTool("key", map[string]any{
			"action": "get",
			"name":   args[0],
		})
		if err != nil {
			handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			output.KeyValue(result)
		}
	},
}

var keyListCmd = &cobra.Command{
	Use:     "list",
	Short:   "List all API keys",
	Long:    "List all API keys with their names, types, and creation dates.",
	Example: "  cyfr key list",
	Run: func(cmd *cobra.Command, args []string) {
		client := newClient()
		result, err := client.CallTool("key", map[string]any{
			"action": "list",
		})
		if err != nil {
			handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			output.KeyValue(result)
		}
	},
}

var keyRevokeCmd = &cobra.Command{
	Use:     "revoke [name]",
	Short:   "Revoke an API key",
	Long:    "Permanently revoke an API key. Existing sessions using this key will be invalidated. Run without arguments for interactive selection.",
	Example: "  cyfr key revoke my-service",
	Args:    cobra.RangeArgs(0, 1),
	Run: func(cmd *cobra.Command, args []string) {
		var name string

		switch {
		case len(args) >= 1:
			name = args[0]
		case prompt.IsInteractive(flagNoInteractive):
			client := newClient()
			opts, err := prompt.FetchKeys(client)
			if err != nil {
				handleToolError(err)
			}
			if len(opts) == 0 {
				output.Error("No keys found. Create one with 'cyfr key create'.")
			}
			selected, err := prompt.SelectOne("Select a key to revoke", opts)
			if err != nil {
				if prompt.IsAborted(err) {
					os.Exit(130)
				}
				output.Errorf("Prompt failed: %v", err)
			}
			confirmed, err := prompt.Confirm(fmt.Sprintf("Revoke key '%s'? This cannot be undone.", selected))
			if err != nil {
				if prompt.IsAborted(err) {
					os.Exit(130)
				}
				output.Errorf("Prompt failed: %v", err)
			}
			if !confirmed {
				fmt.Println("Cancelled.")
				return
			}
			name = selected
		default:
			output.Error("Usage: cyfr key revoke <name>")
		}

		client := newClient()
		result, err := client.CallTool("key", map[string]any{
			"action": "revoke",
			"name":   name,
		})
		if err != nil {
			handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			fmt.Printf("Key '%s' revoked.\n", name)
		}
		_ = result
	},
}

var keyRotateCmd = &cobra.Command{
	Use:     "rotate [name]",
	Short:   "Rotate an API key",
	Long:    "Generate a new key value for an existing key name. The old value stops working immediately. Run without arguments for interactive selection.",
	Example: "  cyfr key rotate my-service",
	Args:    cobra.RangeArgs(0, 1),
	Run: func(cmd *cobra.Command, args []string) {
		var name string

		switch {
		case len(args) >= 1:
			name = args[0]
		case prompt.IsInteractive(flagNoInteractive):
			client := newClient()
			opts, err := prompt.FetchKeys(client)
			if err != nil {
				handleToolError(err)
			}
			if len(opts) == 0 {
				output.Error("No keys found. Create one with 'cyfr key create'.")
			}
			selected, err := prompt.SelectOne("Select a key to rotate", opts)
			if err != nil {
				if prompt.IsAborted(err) {
					os.Exit(130)
				}
				output.Errorf("Prompt failed: %v", err)
			}
			confirmed, err := prompt.Confirm(fmt.Sprintf("Rotate key '%s'? The old value stops working immediately.", selected))
			if err != nil {
				if prompt.IsAborted(err) {
					os.Exit(130)
				}
				output.Errorf("Prompt failed: %v", err)
			}
			if !confirmed {
				fmt.Println("Cancelled.")
				return
			}
			name = selected
		default:
			output.Error("Usage: cyfr key rotate <name>")
		}

		client := newClient()
		result, err := client.CallTool("key", map[string]any{
			"action": "rotate",
			"name":   name,
		})
		if err != nil {
			handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			output.KeyValue(result)
		}
	},
}
