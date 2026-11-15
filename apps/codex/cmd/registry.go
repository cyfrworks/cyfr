// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Registry namespace and push-token management commands.
// Each command delegates to the MCP registry tool, which resolves the push
// tokens CYFR stores for the person. They read; every change the registry
// needs signed by the person (minting, issuing and revoking tokens,
// claiming and verifying a publisher, a namespace's members) is made on
// the screen, on CYFR's Registry page, never here.
package cmd

import (
	"github.com/cyfr/codex/internal/ops"
	"github.com/cyfr/codex/internal/output"
	"github.com/spf13/cobra"
)

func init() {
	// Top-level
	registryCmd.AddCommand(registryWhoamiCmd)
	registryCmd.AddCommand(registryGetNamespaceCmd)

	// tokens
	registryCmd.AddCommand(registryTokensCmd)
	registryTokensCmd.AddCommand(registryTokensListCmd)

	// members
	registryCmd.AddCommand(registryMembersCmd)
	registryMembersCmd.AddCommand(registryMembersListCmd)
}

// ----------------------------------------------------------------------------
// registry whoami — registry identity and memberships
// ----------------------------------------------------------------------------

var registryWhoamiCmd = &cobra.Command{
	Use:   "whoami",
	Short: "Show cyfr.run identity (personal + memberships)",
	Long: `Queries the registry.whoami MCP action and prints cyfr.run identity
state: whether this session holds a push token for this user, which personal
namespace is claimed, and which publisher namespaces the user is a member of.

Alias for the registry half of ` + "`cyfr whoami`" + ` — use this form when
you only want the registry state.`,
	RunE: func(cmd *cobra.Command, args []string) error {
		client := newClient()
		result, err := client.CallTool(cmd.Context(), ops.Registry, ops.RegistryWhoamiArgs{})
		if err != nil {
			return handleToolError(err, "Registry whoami failed")
		}
		if flagJSON {
			output.JSON(result)
			return nil
		}
		output.KeyValue(result)
		return nil
	},
}

// ----------------------------------------------------------------------------
// registry get-namespace <slug>
// ----------------------------------------------------------------------------

var registryGetNamespaceCmd = &cobra.Command{
	Use:   "get-namespace <slug>",
	Short: "Inspect a cyfr.run namespace",
	Long: `Public endpoint — returns the namespace's kind (personal / publisher /
reserved) and its DNS verification status. Works without a push token.`,
	Args:    cobra.ExactArgs(1),
	Example: "  cyfr registry get-namespace stripe.com",
	RunE: func(cmd *cobra.Command, args []string) error {
		slug := args[0]

		client := newClient()
		result, err := client.CallTool(cmd.Context(), ops.Registry, ops.RegistryGetNamespaceArgs{Slug: slug})
		if err != nil {
			return handleToolError(err, "get-namespace failed")
		}

		if flagJSON {
			output.JSON(result)
			return nil
		}
		output.KeyValue(result)
		return nil
	},
}

// ----------------------------------------------------------------------------
// registry tokens list
// ----------------------------------------------------------------------------

var registryTokensCmd = &cobra.Command{
	Use:   "tokens",
	Short: "List a namespace's push tokens; issue and revoke them on CYFR's Registry page",
}

var registryTokensListCmd = &cobra.Command{
	Use:     "list <namespace>",
	Short:   "List push tokens for a namespace",
	Args:    cobra.ExactArgs(1),
	Example: "  cyfr registry tokens list alice",
	RunE: func(cmd *cobra.Command, args []string) error {
		slug := args[0]

		client := newClient()
		result, err := client.CallTool(cmd.Context(), ops.Registry, ops.RegistryTokensListArgs{Slug: slug})
		if err != nil {
			return handleToolError(err, "tokens list failed")
		}
		if flagJSON {
			output.JSON(result)
			return nil
		}
		output.KeyValue(result)
		return nil
	},
}

// ----------------------------------------------------------------------------
// registry members list
// ----------------------------------------------------------------------------

var registryMembersCmd = &cobra.Command{
	Use:   "members",
	Short: "List a publisher namespace's members; change them on CYFR's Registry page",
	Long: `Publisher namespaces have members (admin / member); personal
namespaces do not. Members are added, changed and removed on CYFR's
Registry page.`,
}

var registryMembersListCmd = &cobra.Command{
	Use:     "list <namespace>",
	Short:   "List members of a publisher namespace",
	Args:    cobra.ExactArgs(1),
	Example: "  cyfr registry members list acme.com",
	RunE: func(cmd *cobra.Command, args []string) error {
		slug := args[0]

		client := newClient()
		result, err := client.CallTool(cmd.Context(), ops.Registry, ops.RegistryMembersListArgs{Slug: slug})
		if err != nil {
			return handleToolError(err, "members list failed")
		}
		if flagJSON {
			output.JSON(result)
			return nil
		}
		output.KeyValue(result)
		return nil
	},
}
