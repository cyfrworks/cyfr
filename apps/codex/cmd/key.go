package cmd

import (
	"fmt"

	"github.com/cyfr/codex/internal/output"
	"github.com/spf13/cobra"
)

func init() {
	rootCmd.AddCommand(keyCmd)
	keyCmd.AddCommand(keyCreateCmd)
	keyCmd.AddCommand(keyGetCmd)
	keyCmd.AddCommand(keyListCmd)
	keyCmd.AddCommand(keyRevokeCmd)
	keyCmd.AddCommand(keyRotateCmd)

	keyCreateCmd.Flags().String("name", "", "Key name (required)")
	keyCreateCmd.Flags().String("type", "public", "Key type: public, secret, admin")
	keyCreateCmd.Flags().StringSlice("scope", nil, "Permission scopes")
	keyCreateCmd.Flags().String("rate-limit", "", "Rate limit (e.g., '100/1m')")
	keyCreateCmd.Flags().StringSlice("ip-allowlist", nil, "Allowed IPs/CIDRs")
	_ = keyCreateCmd.MarkFlagRequired("name")
}

var keyCmd = &cobra.Command{
	Use:     "key",
	Short:   "Manage API keys",
	GroupID: "security",
	Long:    "Create, list, rotate, and revoke API keys. Key prefixes indicate type: pk_ (public), sk_ (secret), ak_ (admin).",
}

var keyCreateCmd = &cobra.Command{
	Use:   "create",
	Short: "Create a new API key",
	Long:  "Generate a new API key with the given name, type, and optional scopes, rate limit, and IP allowlist.",
	Example: `  cyfr key create --name my-service --type secret
  cyfr key create --name ci-runner --type public --scope execute,read
  cyfr key create --name prod --type admin --rate-limit 100/1m --ip-allowlist 10.0.0.0/8`,
	Run: func(cmd *cobra.Command, args []string) {
		name, _ := cmd.Flags().GetString("name")
		keyType, _ := cmd.Flags().GetString("type")
		scope, _ := cmd.Flags().GetStringSlice("scope")
		rateLimit, _ := cmd.Flags().GetString("rate-limit")
		ipAllowlist, _ := cmd.Flags().GetStringSlice("ip-allowlist")

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
			output.Errorf("Failed: %v", err)
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
			output.Errorf("Failed: %v", err)
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
			output.Errorf("Failed: %v", err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			output.KeyValue(result)
		}
	},
}

var keyRevokeCmd = &cobra.Command{
	Use:     "revoke <name>",
	Short:   "Revoke an API key",
	Long:    "Permanently revoke an API key. Existing sessions using this key will be invalidated.",
	Example: "  cyfr key revoke my-service",
	Args:    cobra.ExactArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		client := newClient()
		result, err := client.CallTool("key", map[string]any{
			"action": "revoke",
			"name":   args[0],
		})
		if err != nil {
			output.Errorf("Failed: %v", err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			fmt.Printf("Key '%s' revoked.\n", args[0])
		}
		_ = result
	},
}

var keyRotateCmd = &cobra.Command{
	Use:     "rotate <name>",
	Short:   "Rotate an API key",
	Long:    "Generate a new key value for an existing key name. The old value stops working immediately.",
	Example: "  cyfr key rotate my-service",
	Args:    cobra.ExactArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		client := newClient()
		result, err := client.CallTool("key", map[string]any{
			"action": "rotate",
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
