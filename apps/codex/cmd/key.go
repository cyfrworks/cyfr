// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"context"
	"errors"
	"fmt"
	"github.com/cyfr/codex/internal/ops"
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
	keyCreateCmd.Flags().StringSlice("scope", nil, "What the key may do (execute, component_read, storage_read, component_manage, storage_write, admin, vault_read)")
	keyCreateCmd.Flags().StringSlice("tool", nil, "The only tools the key may run, each named without its version (c:local.my-tool)")
	keyCreateCmd.Flags().StringSlice("ip-allowlist", nil, "Allowed IPs/CIDRs")
}

var keyCmd = &cobra.Command{
	Use:     "key",
	Short:   "Manage API keys",
	GroupID: "security",
	Long:    "Create, list, rotate, and revoke API keys. A key (cyfr_sk_) acts as you in your athanor, within the permissions and tools it was made with, which never change.",
}

var keyCreateCmd = &cobra.Command{
	Use:   "create",
	Short: "Create a new API key",
	Long: `Generate a new API key with the given name. What it may do is fixed once it is made.
Run without --name for an interactive form.

Without --scope the key may run tools and read their runs (execute, component_read,
storage_read). Without --tool it runs any tool you granted.`,
	Example: `  cyfr key create --name ci-runner
  cyfr key create --name deploy --tool c:local.ship
  cyfr key create --name builder --scope execute,component_read,storage_read,component_manage,storage_write
  cyfr key create --name ops --scope admin --ip-allowlist 10.0.0.0/8`,
	RunE: func(cmd *cobra.Command, args []string) error {
		name, _ := cmd.Flags().GetString("name")
		scope, _ := cmd.Flags().GetStringSlice("scope")
		tools, _ := cmd.Flags().GetStringSlice("tool")
		ipAllowlist, _ := cmd.Flags().GetStringSlice("ip-allowlist")

		// If --name not provided, try interactive mode
		if name == "" {
			if !prompt.IsInteractive(flagNoInteractive) {
				return errors.New("--name is required. Usage: cyfr key create --name <name>")
			}

			form, err := prompt.RunKeyCreateForm(cmd.Context())
			if err != nil {
				if prompt.IsAborted(err) {
					return prompt.ErrAborted
				}
				return fmt.Errorf("Prompt failed: %w", err)
			}
			name = form.Name
			if len(form.Scopes) > 0 {
				scope = form.Scopes
			}
			if form.Tools != "" {
				tools = strings.FieldsFunc(form.Tools, func(r rune) bool { return r == ',' || r == ' ' })
			}
			if form.IPAllowlist != "" {
				ipAllowlist = strings.Split(form.IPAllowlist, ",")
			}
		}

		toolArgs := ops.KeyCreateArgs{Name: name}
		if len(scope) > 0 {
			toolArgs.Scope = ops.Value(scope)
		}
		if len(tools) > 0 {
			toolArgs.Tools = ops.Value(tools)
		}
		if len(ipAllowlist) > 0 {
			toolArgs.IpAllowlist = ops.Value(ipAllowlist)
		}

		client := newClient()
		result, err := client.CallTool(cmd.Context(), ops.Key, toolArgs)
		if err != nil {
			return handleToolError(err)
		}
		return renderResult(result)
	},
}

var keyGetCmd = &cobra.Command{
	Use:     "get <name>",
	Short:   "Get key info",
	Long:    "Show an API key's permissions and tools.",
	Example: "  cyfr key get my-service",
	Args:    cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		client := newClient()
		result, err := client.CallTool(cmd.Context(), ops.Key, ops.KeyGetArgs{Name: args[0]})
		if err != nil {
			return handleToolError(err)
		}
		return renderResult(result)
	},
}

var keyListCmd = &cobra.Command{
	Use:     "list",
	Short:   "List all API keys",
	Long:    "List all API keys with their names, permissions, tools and creation dates.",
	Example: "  cyfr key list",
	RunE: func(cmd *cobra.Command, args []string) error {
		client := newClient()
		result, err := client.CallTool(cmd.Context(), ops.Key, ops.KeyListArgs{})
		if err != nil {
			return handleToolError(err)
		}
		return renderResult(result)
	},
}

var keyRevokeCmd = &cobra.Command{
	Use:     "revoke [name]",
	Short:   "Revoke an API key",
	Long:    "Permanently revoke an API key. Existing sessions using this key will be invalidated. Run without arguments for interactive selection.",
	Example: "  cyfr key revoke my-service",
	Args:    cobra.RangeArgs(0, 1),
	RunE: func(cmd *cobra.Command, args []string) error {
		name, err := pickTarget(cmd.Context(), args, selector{
			Title:   "Select a key to revoke",
			Confirm: "Revoke key '%s'? This cannot be undone.",
			Empty:   "No keys found. Create one with 'cyfr key create'.",
			Usage:   "Usage: cyfr key revoke <name>",
			Fetch: func(ctx context.Context) ([]prompt.Option, error) {
				return prompt.FetchKeys(ctx, newClient())
			},
		})
		if err != nil || name == "" {
			return err
		}

		client := newClient()
		result, err := client.CallTool(cmd.Context(), ops.Key, ops.KeyRevokeArgs{Name: name})
		if err != nil {
			return handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			fmt.Printf("Key '%s' revoked.\n", name)
		}
		return nil
	},
}

var keyRotateCmd = &cobra.Command{
	Use:     "rotate [name]",
	Short:   "Rotate an API key",
	Long:    "Generate a new key value for an existing key name. The old value stops working immediately. Run without arguments for interactive selection.",
	Example: "  cyfr key rotate my-service",
	Args:    cobra.RangeArgs(0, 1),
	RunE: func(cmd *cobra.Command, args []string) error {
		name, err := pickTarget(cmd.Context(), args, selector{
			Title:   "Select a key to rotate",
			Confirm: "Rotate key '%s'? The old value stops working immediately.",
			Empty:   "No keys found. Create one with 'cyfr key create'.",
			Usage:   "Usage: cyfr key rotate <name>",
			Fetch: func(ctx context.Context) ([]prompt.Option, error) {
				return prompt.FetchKeys(ctx, newClient())
			},
		})
		if err != nil || name == "" {
			return err
		}

		client := newClient()
		result, err := client.CallTool(cmd.Context(), ops.Key, ops.KeyRotateArgs{Name: name})
		if err != nil {
			return handleToolError(err)
		}
		return renderResult(result)
	},
}
