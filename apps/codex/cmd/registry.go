// Package cmd — cyfr.run namespace + push-token management subcommands.
//
// This file is the client side of the MCP `registry` tool. Each cobra
// command delegates to an action on that tool (defined on the server in
// apps/cyfr/lib/compendium/mcp.ex); no authentication is performed
// locally — the server resolves the caller's bearer from CredentialStore
// based on Context.user_id.
//
// The existing `registry` cobra root lives in cmd/component.go (alongside
// `registry discover`). This file ADDS subcommands under the same root:
//
//	cyfr registry whoami
//	cyfr registry probe
//	cyfr registry get-namespace <slug>
//	cyfr registry publisher claim <domain>
//	cyfr registry publisher verify <domain>
//	cyfr registry tokens list   <namespace>
//	cyfr registry tokens issue  <namespace> [--label TEXT]
//	cyfr registry tokens revoke <namespace> <token_id>
//	cyfr registry members list   <namespace>
//	cyfr registry members add    <namespace> <target-personal-slug> [--role admin|member]
//	cyfr registry members update <namespace> <target-personal-slug> [--role admin|member]
//	cyfr registry members remove <namespace> <target-personal-slug>
//
// `registry login` (pre-refactor Basic-auth-over-OCI) is intentionally gone.
// Push credentials are per-user opaque tokens provisioned by `cyfr login`.
package cmd

import (
	"fmt"

	"github.com/cyfr/codex/internal/output"
	"github.com/spf13/cobra"
)

var (
	flagTokenLabel string
	flagMemberRole string
)

func init() {
	// Top-level
	registryCmd.AddCommand(registryWhoamiCmd)
	registryCmd.AddCommand(registryProbeCmd)
	registryCmd.AddCommand(registryGetNamespaceCmd)

	// publisher
	registryCmd.AddCommand(registryPublisherCmd)
	registryPublisherCmd.AddCommand(registryPublisherClaimCmd)
	registryPublisherCmd.AddCommand(registryPublisherVerifyCmd)

	// tokens
	registryCmd.AddCommand(registryTokensCmd)
	registryTokensIssueCmd.Flags().StringVar(&flagTokenLabel, "label", "",
		"Human-readable label for the issued push token (default: hostname)")
	registryTokensCmd.AddCommand(registryTokensListCmd)
	registryTokensCmd.AddCommand(registryTokensIssueCmd)
	registryTokensCmd.AddCommand(registryTokensRevokeCmd)

	// members
	registryCmd.AddCommand(registryMembersCmd)
	registryMembersAddCmd.Flags().StringVar(&flagMemberRole, "role", "member",
		"Role for the member (admin or member)")
	registryMembersUpdateCmd.Flags().StringVar(&flagMemberRole, "role", "",
		"New role for the member (admin or member)")
	registryMembersCmd.AddCommand(registryMembersListCmd)
	registryMembersCmd.AddCommand(registryMembersAddCmd)
	registryMembersCmd.AddCommand(registryMembersUpdateCmd)
	registryMembersCmd.AddCommand(registryMembersRemoveCmd)
}

// ----------------------------------------------------------------------------
// registry whoami — two-action compose (same shape as top-level `cyfr whoami`)
// ----------------------------------------------------------------------------

var registryWhoamiCmd = &cobra.Command{
	Use:   "whoami",
	Short: "Show cyfr.run identity (personal + memberships)",
	Long: `Queries the registry.whoami MCP action and prints cyfr.run identity
state: whether this session holds a push token for this user, which personal
namespace is claimed, and which publisher namespaces the user is a member of.

Alias for the registry half of ` + "`cyfr whoami`" + ` — use this form when
you only want the registry state.`,
	Run: func(cmd *cobra.Command, args []string) {
		client := newClient()
		result, err := client.CallTool("registry", map[string]any{"action": "whoami"})
		if err != nil {
			handleToolError(err, "Registry whoami failed")
		}
		if flagJSON {
			output.JSON(result)
			return
		}
		output.KeyValue(result)
	},
}

// ----------------------------------------------------------------------------
// registry probe — manual re-sync of push tokens
// ----------------------------------------------------------------------------

var registryProbeCmd = &cobra.Command{
	Use:   "probe",
	Short: "Re-sync push tokens with cyfr.run",
	Long: `Refreshes the cyfr.run push-token state for the current session.

Normally the probe runs automatically during ` + "`cyfr login`" + ` — this
command exists as the manual retry path for when memberships change on
another device, or when the automatic probe transiently failed.

# In-place re-probe not yet supported

This command currently DOES NOT re-probe in-place. It forwards the user
to ` + "`cyfr login`" + ` instead because:

  1. /v1/identity/probe requires an IdP access_token to prove identity.
  2. codex does not cache the access_token between commands — it's a
     single-use secret that device-poll returns once, ` + "`cmd/login.go`" + `
     consumes for the one-shot personal-namespace claim, and discards.
  3. A true re-probe would require either (a) caching the access_token
     securely between commands (needs keychain / OS secret store) or (b) a
     server-side session-token-backed probe (new MCP action that uses the
     Sanctum session to re-verify via the IdP on the server's behalf).

Until either path lands, ` + "`cyfr login`" + ` is the canonical refresh. The
server-side behavior is idempotent — a fresh DeviceFlow on an already-valid
session re-runs the probe, re-populates CredentialStore entries, and
returns the same session_id back.`,
	Args: cobra.NoArgs,
	Run: func(cmd *cobra.Command, args []string) {
		fmt.Fprintln(cmd.ErrOrStderr(),
			"`cyfr registry probe` currently forwards to `cyfr login` — see "+
				"`cyfr registry probe --help` for the rationale.")
		fmt.Fprintln(cmd.ErrOrStderr(),
			"Run `cyfr login` to refresh push tokens for your namespaces.")
	},
}

// ----------------------------------------------------------------------------
// registry get-namespace <slug>
// ----------------------------------------------------------------------------

var registryGetNamespaceCmd = &cobra.Command{
	Use:   "get-namespace <slug>",
	Short: "Inspect a cyfr.run namespace",
	Long: `Public endpoint — returns the namespace's kind (personal / publisher /
reserved), DNS verification status, and the provider that originally claimed
it. Works without a push token.`,
	Args:    cobra.ExactArgs(1),
	Example: "  cyfr registry get-namespace stripe.com",
	Run: func(cmd *cobra.Command, args []string) {
		slug := args[0]

		client := newClient()
		result, err := client.CallTool("registry", map[string]any{
			"action": "get-namespace",
			"slug":   slug,
		})
		if err != nil {
			handleToolError(err, "get-namespace failed")
		}

		if flagJSON {
			output.JSON(result)
			return
		}
		output.KeyValue(result)
	},
}

// ----------------------------------------------------------------------------
// registry publisher {claim,verify}
// ----------------------------------------------------------------------------

var registryPublisherCmd = &cobra.Command{
	Use:   "publisher",
	Short: "Claim and verify publisher namespaces (DNS-authenticated)",
}

var registryPublisherClaimCmd = &cobra.Command{
	Use:   "claim <domain>",
	Short: "Start a publisher-namespace claim (issues a DNS TXT challenge)",
	Long: `Requires a push token for your personal namespace (get one via
` + "`cyfr login`" + `). cyfr.run returns a TXT challenge to install at
_cyfr-verify.<domain>; run ` + "`cyfr registry publisher verify <domain>`" + ` once
the record is live.`,
	Args:    cobra.ExactArgs(1),
	Example: "  cyfr registry publisher claim acme.com",
	Run: func(cmd *cobra.Command, args []string) {
		slug := args[0]

		client := newClient()
		result, err := client.CallTool("registry", map[string]any{
			"action": "claim-publisher",
			"slug":   slug,
		})
		if err != nil {
			handleToolError(err, "Publisher claim failed")
		}

		if flagJSON {
			output.JSON(result)
			return
		}
		output.KeyValue(result)
	},
}

var registryPublisherVerifyCmd = &cobra.Command{
	Use:   "verify <domain>",
	Short: "Verify a publisher claim via DNS and receive the first push token",
	Long: `Polls the DNS TXT record installed for a prior ` + "`claim`" + `. On
success the caller becomes the sole admin of the publisher namespace and
cyfr.run issues the first push token for it — stored server-side in the
user's CredentialStore so ` + "`cyfr publish`" + ` can use it immediately.`,
	Args:    cobra.ExactArgs(1),
	Example: "  cyfr registry publisher verify acme.com",
	Run: func(cmd *cobra.Command, args []string) {
		slug := args[0]

		client := newClient()
		result, err := client.CallTool("registry", map[string]any{
			"action": "verify-publisher",
			"slug":   slug,
		})
		if err != nil {
			handleToolError(err, "Publisher verify failed")
		}

		if flagJSON {
			output.JSON(result)
			return
		}
		output.KeyValue(result)
	},
}

// ----------------------------------------------------------------------------
// registry tokens {list,issue,revoke}
// ----------------------------------------------------------------------------

var registryTokensCmd = &cobra.Command{
	Use:   "tokens",
	Short: "Manage push tokens for a namespace",
}

var registryTokensListCmd = &cobra.Command{
	Use:     "list <namespace>",
	Short:   "List push tokens for a namespace",
	Args:    cobra.ExactArgs(1),
	Example: "  cyfr registry tokens list alice",
	Run: func(cmd *cobra.Command, args []string) {
		slug := args[0]

		client := newClient()
		result, err := client.CallTool("registry", map[string]any{
			"action": "tokens-list",
			"slug":   slug,
		})
		if err != nil {
			handleToolError(err, "tokens list failed")
		}
		if flagJSON {
			output.JSON(result)
			return
		}
		output.KeyValue(result)
	},
}

var registryTokensIssueCmd = &cobra.Command{
	Use:   "issue <namespace>",
	Short: "Issue an additional push token for a namespace",
	Long: `Mints a new push token scoped to the given namespace. Useful for
per-device or per-CI tokens — each token can be revoked independently via
` + "`tokens revoke`" + `. Rate limited to 10 tokens per hour per bearer.`,
	Args:    cobra.ExactArgs(1),
	Example: "  cyfr registry tokens issue acme.com --label laptop",
	Run: func(cmd *cobra.Command, args []string) {
		slug := args[0]

		args2 := map[string]any{
			"action": "tokens-issue",
			"slug":   slug,
		}
		if flagTokenLabel != "" {
			args2["label"] = flagTokenLabel
		}

		client := newClient()
		result, err := client.CallTool("registry", args2)
		if err != nil {
			handleToolError(err, "tokens issue failed")
		}
		if flagJSON {
			output.JSON(result)
			return
		}
		output.KeyValue(result)
	},
}

var registryTokensRevokeCmd = &cobra.Command{
	Use:   "revoke <namespace> <token_id>",
	Short: "Revoke a push token by id",
	Long: `Revocation is immediate on the server side — the next push request
using the revoked token returns 401. Does not affect tokens held by other
members of the namespace.`,
	Args:    cobra.ExactArgs(2),
	Example: "  cyfr registry tokens revoke acme.com 01H8K9XZ...",
	Run: func(cmd *cobra.Command, args []string) {
		slug := args[0]
		tokenID := args[1]

		client := newClient()
		result, err := client.CallTool("registry", map[string]any{
			"action":   "tokens-revoke",
			"slug":     slug,
			"token_id": tokenID,
		})
		if err != nil {
			handleToolError(err, "tokens revoke failed")
		}
		if flagJSON {
			output.JSON(result)
			return
		}
		fmt.Printf("Revoked token %s for namespace %s\n", tokenID, slug)
	},
}

// ----------------------------------------------------------------------------
// registry members {list,add,update,remove}
// ----------------------------------------------------------------------------

var registryMembersCmd = &cobra.Command{
	Use:   "members",
	Short: "Manage members of a publisher namespace",
	Long: `Publisher namespaces have members (admin / member). Personal
namespaces do not — the server returns an error if you try to add members to
a personal namespace.

The target user's PERSONAL namespace slug is the identifier — e.g. to add
Alice (whose personal namespace is 'alice') as a member of acme.com, run
` + "`cyfr registry members add acme.com alice`" + `.`,
}

var registryMembersListCmd = &cobra.Command{
	Use:     "list <namespace>",
	Short:   "List members of a publisher namespace",
	Args:    cobra.ExactArgs(1),
	Example: "  cyfr registry members list acme.com",
	Run: func(cmd *cobra.Command, args []string) {
		slug := args[0]

		client := newClient()
		result, err := client.CallTool("registry", map[string]any{
			"action": "members-list",
			"slug":   slug,
		})
		if err != nil {
			handleToolError(err, "members list failed")
		}
		if flagJSON {
			output.JSON(result)
			return
		}
		output.KeyValue(result)
	},
}

var registryMembersAddCmd = &cobra.Command{
	Use:     "add <namespace> <target-personal-slug>",
	Short:   "Add a member to a publisher namespace (admin-only)",
	Args:    cobra.ExactArgs(2),
	Example: "  cyfr registry members add acme.com alice --role member",
	Run: func(cmd *cobra.Command, args []string) {
		slug := args[0]
		target := args[1]
		role := flagMemberRole
		if role == "" {
			role = "member"
		}
		if role != "admin" && role != "member" {
			output.Errorf("Invalid role %q — must be 'admin' or 'member'.", role)
		}

		client := newClient()
		result, err := client.CallTool("registry", map[string]any{
			"action":                "members-add",
			"slug":                  slug,
			"target_personal_slug":  target,
			"role":                  role,
		})
		if err != nil {
			handleToolError(err, "members add failed")
		}
		if flagJSON {
			output.JSON(result)
			return
		}
		fmt.Printf("Added %s to %s as %s\n", target, slug, role)
	},
}

var registryMembersUpdateCmd = &cobra.Command{
	Use:   "update <namespace> <target-personal-slug>",
	Short: "Update a member's role (admin-only)",
	Long: `Change an existing member's role. Sole-admin protection: demoting or
removing the last admin returns 409 ` + "`sole_admin`" + ` — promote another
member first.`,
	Args:    cobra.ExactArgs(2),
	Example: "  cyfr registry members update acme.com alice --role admin",
	Run: func(cmd *cobra.Command, args []string) {
		slug := args[0]
		target := args[1]
		role := flagMemberRole
		if role == "" {
			output.Error("--role is required (admin or member)")
		}
		if role != "admin" && role != "member" {
			output.Errorf("Invalid role %q — must be 'admin' or 'member'.", role)
		}

		client := newClient()
		result, err := client.CallTool("registry", map[string]any{
			"action":                "members-update",
			"slug":                  slug,
			"target_personal_slug":  target,
			"role":                  role,
		})
		if err != nil {
			handleToolError(err, "members update failed")
		}
		if flagJSON {
			output.JSON(result)
			return
		}
		fmt.Printf("Updated %s in %s to %s\n", target, slug, role)
	},
}

var registryMembersRemoveCmd = &cobra.Command{
	Use:   "remove <namespace> <target-personal-slug>",
	Short: "Remove a member from a publisher namespace (admin-only)",
	Long: `Server atomically revokes the removed user's push tokens for this
namespace — next-request effective. Sole-admin protection applies: removing
the last admin returns 409 ` + "`sole_admin`" + `.`,
	Args:    cobra.ExactArgs(2),
	Example: "  cyfr registry members remove acme.com alice",
	Run: func(cmd *cobra.Command, args []string) {
		slug := args[0]
		target := args[1]

		client := newClient()
		result, err := client.CallTool("registry", map[string]any{
			"action":                "members-remove",
			"slug":                  slug,
			"target_personal_slug":  target,
		})
		if err != nil {
			handleToolError(err, "members remove failed")
		}
		if flagJSON {
			output.JSON(result)
			return
		}
		fmt.Printf("Removed %s from %s\n", target, slug)
	},
}
