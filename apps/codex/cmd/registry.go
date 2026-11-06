// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Registry namespace and push-token management commands.
// Each command delegates to the MCP registry tool, which resolves the push
// tokens CYFR stores for the person. A request the registry needs signed
// by the person is signed here, by this command line's own key after its
// unlock (signedRegistry); CYFR holds no key of the person's. A person's
// name, their personal namespace, is taken at the registry when their
// account is made; `cyfr registry sync` provisions push tokens, which
// sign-in never does.
package cmd

import (
	"context"
	"errors"
	"fmt"
	"maps"
	"os"
	"slices"
	"strings"

	"github.com/cyfr/codex/internal/account"
	"github.com/cyfr/codex/internal/holder"
	"github.com/cyfr/codex/internal/mcp"
	"github.com/cyfr/codex/internal/ops"
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
	registryCmd.AddCommand(registrySyncCmd)
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
// registry sync — mint and store push tokens
// ----------------------------------------------------------------------------

var registrySyncCmd = &cobra.Command{
	Use:   "sync",
	Short: "Mint and store your push tokens at cyfr.run",
	Long: `Mints push tokens for your personal namespace and every publisher
namespace you are a member of, and stores them on the server for ` + "`cyfr push`" + `.
The registry takes the mint as a request your account signs: this command
shows it and asks this command line's PIN or passphrase to sign it, every
time.

Prints your personal namespace and your memberships. No token is ever printed.
Run it again after a token is revoked or a membership is added.`,
	Args:    cobra.NoArgs,
	Example: "  cyfr registry sync",
	RunE: func(cmd *cobra.Command, args []string) error {
		client := newClient()
		result, err := signedRegistry(cmd.Context(), client, func(answer ops.Field[any]) (map[string]any, error) {
			return client.CallTool(cmd.Context(), ops.Registry, ops.RegistrySyncArgs{Answer: answer})
		})
		if err != nil {
			return handleToolError(err, "Registry sync failed")
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
// registry publisher {claim,verify}
// ----------------------------------------------------------------------------

var registryPublisherCmd = &cobra.Command{
	Use:   "publisher",
	Short: "Claim and verify publisher namespaces (DNS-authenticated)",
}

var registryPublisherClaimCmd = &cobra.Command{
	Use:   "claim <domain>",
	Short: "Start a publisher-namespace claim (issues a DNS TXT challenge)",
	Long: `Sent as a request your account signs, with this command line's PIN or
passphrase, so it needs your name at the registry, taken when your account
was made. The registry returns a TXT challenge to install at
_cyfr-verify.<domain>; run
` + "`cyfr registry publisher verify <domain>`" + ` once the record is live.`,
	Args:    cobra.ExactArgs(1),
	Example: "  cyfr registry publisher claim acme.com",
	RunE: func(cmd *cobra.Command, args []string) error {
		slug := args[0]

		client := newClient()
		result, err := signedRegistry(cmd.Context(), client, func(answer ops.Field[any]) (map[string]any, error) {
			return client.CallTool(cmd.Context(), ops.Registry, ops.RegistryClaimPublisherArgs{Slug: slug, Answer: answer})
		})
		if err != nil {
			return handleToolError(err, "Publisher claim failed")
		}

		if flagJSON {
			output.JSON(result)
			return nil
		}
		output.KeyValue(result)
		return nil
	},
}

var registryPublisherVerifyCmd = &cobra.Command{
	Use:   "verify <domain>",
	Short: "Verify a publisher claim via DNS and store its first push token",
	Long: `Polls the DNS TXT record installed for a prior ` + "`claim`" + `, with a
request your account signs, with this command line's PIN or passphrase. On
success the caller becomes the sole admin of the publisher namespace and
cyfr.run mints the founding member's push token, which the server stores so
` + "`cyfr push`" + ` can use it immediately; ` + "`token_stored`" + ` says whether
it was. A repeat of a verification already recorded mints nothing — run
` + "`cyfr registry sync`" + ` for the token then.`,
	Args:    cobra.ExactArgs(1),
	Example: "  cyfr registry publisher verify acme.com",
	RunE: func(cmd *cobra.Command, args []string) error {
		slug := args[0]

		client := newClient()
		result, err := signedRegistry(cmd.Context(), client, func(answer ops.Field[any]) (map[string]any, error) {
			return client.CallTool(cmd.Context(), ops.Registry, ops.RegistryVerifyPublisherArgs{Slug: slug, Answer: answer})
		})
		if err != nil {
			return handleToolError(err, "Publisher verify failed")
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

var registryTokensIssueCmd = &cobra.Command{
	Use:   "issue <namespace>",
	Short: "Issue an additional push token for a namespace",
	Long: `Mints a new push token scoped to the given namespace. Useful for
per-device or per-CI tokens — each token can be revoked independently via
` + "`tokens revoke`" + `. Rate limited to 10 tokens per hour per bearer.`,
	Args:    cobra.ExactArgs(1),
	Example: "  cyfr registry tokens issue acme.com --label laptop",
	RunE: func(cmd *cobra.Command, args []string) error {
		slug := args[0]

		args2 := ops.RegistryTokensIssueArgs{Slug: slug}
		if flagTokenLabel != "" {
			args2.Label = ops.Value(flagTokenLabel)
		}

		client := newClient()
		result, err := client.CallTool(cmd.Context(), ops.Registry, args2)
		if err != nil {
			return handleToolError(err, "tokens issue failed")
		}
		if flagJSON {
			output.JSON(result)
			return nil
		}
		output.KeyValue(result)
		return nil
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
	RunE: func(cmd *cobra.Command, args []string) error {
		slug := args[0]
		tokenID := args[1]

		client := newClient()
		result, err := client.CallTool(cmd.Context(), ops.Registry, ops.RegistryTokensRevokeArgs{Slug: slug,
			TokenId: tokenID})
		if err != nil {
			return handleToolError(err, "tokens revoke failed")
		}
		if flagJSON {
			output.JSON(result)
			return nil
		}
		fmt.Printf("Revoked token %s for namespace %s\n", tokenID, slug)
		return nil
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

var registryMembersAddCmd = &cobra.Command{
	Use:     "add <namespace> <target-personal-slug>",
	Short:   "Add a member to a publisher namespace (admin-only)",
	Args:    cobra.ExactArgs(2),
	Example: "  cyfr registry members add acme.com alice --role member",
	RunE: func(cmd *cobra.Command, args []string) error {
		slug := args[0]
		target := args[1]
		role := flagMemberRole
		if role == "" {
			role = "member"
		}
		if role != "admin" && role != "member" {
			return fmt.Errorf("Invalid role %q — must be 'admin' or 'member'.", role)
		}

		client := newClient()
		result, err := client.CallTool(cmd.Context(), ops.Registry, ops.RegistryMembersAddArgs{Slug: slug,
			TargetPersonalSlug: target,
			Role:               role})
		if err != nil {
			return handleToolError(err, "members add failed")
		}
		if flagJSON {
			output.JSON(result)
			return nil
		}
		fmt.Printf("Added %s to %s as %s\n", target, slug, role)
		return nil
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
	RunE: func(cmd *cobra.Command, args []string) error {
		slug := args[0]
		target := args[1]
		role := flagMemberRole
		if role == "" {
			return errors.New("--role is required (admin or member)")
		}
		if role != "admin" && role != "member" {
			return fmt.Errorf("Invalid role %q — must be 'admin' or 'member'.", role)
		}

		client := newClient()
		result, err := client.CallTool(cmd.Context(), ops.Registry, ops.RegistryMembersUpdateArgs{Slug: slug,
			TargetPersonalSlug: target,
			Role:               role})
		if err != nil {
			return handleToolError(err, "members update failed")
		}
		if flagJSON {
			output.JSON(result)
			return nil
		}
		fmt.Printf("Updated %s in %s to %s\n", target, slug, role)
		return nil
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
	RunE: func(cmd *cobra.Command, args []string) error {
		slug := args[0]
		target := args[1]

		client := newClient()
		result, err := client.CallTool(cmd.Context(), ops.Registry, ops.RegistryMembersRemoveArgs{Slug: slug,
			TargetPersonalSlug: target})
		if err != nil {
			return handleToolError(err, "members remove failed")
		}
		if flagJSON {
			output.JSON(result)
			return nil
		}
		fmt.Printf("Removed %s from %s\n", target, slug)
		return nil
	},
}

// signedRegistry makes a registry action the person signs, in its two
// calls: made without an answer it answers {request}, the CYFR's request
// of purpose registry, whose registry request this command line signs
// with its own key after its unlock (registrySigner); call is then made
// again with the same arguments and that signed request as its answer. An
// action that answers anything else answers it as it is.
func signedRegistry(ctx context.Context, client *mcp.Client, call func(answer ops.Field[any]) (map[string]any, error)) (map[string]any, error) {
	result, err := call(ops.Field[any]{})
	if err != nil {
		return nil, err
	}
	asked, ok := result["request"]
	if !ok || len(result) != 1 {
		return result, nil
	}
	answer, err := registrySigner(ctx, client.BaseURL, asked)
	if err != nil {
		return nil, err
	}
	return call(ops.Value(answer))
}

// registrySigner signs the registry request asked carries with this
// command line's key, asking its PIN or passphrase at the terminal after
// showing what is signed; a test stands in for it.
var registrySigner = func(ctx context.Context, address string, asked any) (any, error) {
	if !askTerminal() {
		return nil, errors.New("The registry asks for your signature, which this command line gives at a terminal with its PIN or passphrase.")
	}
	path, err := deviceKey()
	if err != nil {
		return nil, err
	}
	rec, err := holder.Load(path)
	if err != nil || rec.Identifier == "" {
		return nil, errors.New("The registry asks for your signature, and this command line holds no key of your account: run cyfr login first.")
	}
	c := newConsole(os.Stdout)
	return signRegistryRequest(ctx, c, rec, deviceHome(address), asked)
}

// signRegistryRequest signs the registry request a CYFR's request of
// purpose registry carries, for the account rec's key is listed in: only a
// request this CYFR (home) minted for that account, shown before the
// secret is asked; its signer set to this key's kid, its sig this key's
// Ed25519 signature over its JCS bytes without sig. It answers the signed
// request as a JSON object.
func signRegistryRequest(ctx context.Context, c *console, rec *holder.Record, home string, asked any) (any, error) {
	r, err := account.ReadRequest(asked)
	if err != nil || r.Purpose != "registry" || !sameAddress(r.Audience, home) || r.RegistryRequest["identifier"] != rec.Identifier {
		return nil, errors.New("CYFR asked this command line to sign something other than a registry request for your account here, so nothing was signed.")
	}
	req := r.RegistryRequest
	fmt.Fprintf(c.out, "The registry %s asks your signature for %s", req["registry"], req["operation"])
	if body, ok := req["body"].(map[string]any); ok && len(body) > 0 {
		var parts []string
		for _, k := range slices.Sorted(maps.Keys(body)) {
			parts = append(parts, fmt.Sprintf("%s: %v", k, body[k]))
		}
		fmt.Fprintf(c.out, " (%s)", strings.Join(parts, "; "))
	}
	fmt.Fprintln(c.out, ".")
	question := "Sign it with this command line's passphrase: "
	if rec.Kind == holder.KindChip {
		question = "Sign it with this command line's PIN: "
	}
	secret, err := c.secret(ctx, question)
	if err != nil {
		return nil, err
	}
	key, err := rec.Open(secret)
	clear(secret)
	if errors.Is(err, holder.ErrWrongSecret) || errors.Is(err, holder.ErrSecretShape) {
		return nil, errors.New("That is not this command line's PIN or passphrase. Nothing was signed.")
	}
	if err != nil {
		return nil, fmt.Errorf("This command line's key did not open (%v). Nothing was signed.", err)
	}
	defer key.Erase()
	signer := map[string]any{}
	for k, v := range req {
		signer[k] = v
	}
	signer["signer"] = account.Kid(rec.PublicKey)
	signed, err := account.SignRegistryRequestBy(signer, key.Sign)
	if err != nil {
		return nil, fmt.Errorf("The registry request could not be signed (%v).", err)
	}
	return account.Decode(signed)
}
