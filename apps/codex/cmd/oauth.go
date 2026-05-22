package cmd

import (
	"fmt"

	"github.com/cyfr/codex/internal/output"
	"github.com/spf13/cobra"
)

// cyfr oauth — manage a component's host-managed OAuth access to user-scoped
// third-party APIs (Gmail, Google Calendar, Slack, …). Thin wrapper over the
// `oauth` MCP tool (actions: authorize, status, revoke). This is distinct from
// `cyfr login` (a human signing in to CYFR): here CYFR holds the OAuth tokens
// on the user's behalf and the WASM component only ever receives short-lived
// access tokens at runtime.

var (
	oauthAuthorizePinVersion bool
	oauthRevokePinVersion    bool
)

func init() {
	rootCmd.AddCommand(oauthCmd)
	oauthCmd.AddCommand(oauthAuthorizeCmd)
	oauthCmd.AddCommand(oauthStatusCmd)
	oauthCmd.AddCommand(oauthRevokeCmd)

	oauthAuthorizeCmd.Flags().BoolVar(&oauthAuthorizePinVersion, "pin-version", false,
		"Authorize this exact version instead of name-level (applies to all versions)")
	oauthRevokeCmd.Flags().BoolVar(&oauthRevokePinVersion, "pin-version", false,
		"Revoke for this exact version instead of name-level")
}

var oauthCmd = &cobra.Command{
	Use:     "oauth",
	Short:   "Manage a component's OAuth access to third-party user APIs",
	GroupID: "security",
	Long: `Authorize, check, or revoke a component's access to a user-scoped third-party
API (Gmail, Google Calendar, Slack, …). CYFR manages the OAuth lifecycle and
holds the tokens; the component only receives short-lived access tokens at
runtime. This is separate from "cyfr login", which signs a human in to CYFR.

Authorization is also offered interactively as part of "cyfr setup".`,
}

var oauthAuthorizeCmd = &cobra.Command{
	Use:   "authorize <ref> <provider>",
	Short: "Authorize a component for a provider (opens browser consent)",
	Example: `  cyfr oauth authorize c:local.gmail:0.1.0 google
  cyfr oauth authorize catalyst:local.calendar google`,
	Args: cobra.ExactArgs(2),
	Run: func(cmd *cobra.Command, args []string) {
		ref := args[0]
		provider := args[1]

		client := newClient()
		toolArgs := map[string]any{
			"action":        "authorize",
			"component_ref": ref,
			"provider":      provider,
		}
		if oauthAuthorizePinVersion {
			toolArgs["pin_version"] = true
		}

		result, err := client.CallTool("oauth", toolArgs)
		if err != nil {
			handleToolError(err, "OAuth authorize failed")
		}
		if flagJSON {
			output.JSON(result)
			return
		}

		if authURL, ok := result["authorize_url"].(string); ok {
			fmt.Printf("\n  Visit this URL to authorize '%s' for %s:\n  %s\n", provider, ref, authURL)
		}
		if msg, ok := result["message"].(string); ok {
			fmt.Printf("\n  %s\n", msg)
		}
	},
}

var oauthStatusCmd = &cobra.Command{
	Use:     "status <ref>",
	Short:   "Show authorization status for each declared provider",
	Example: `  cyfr oauth status c:local.gmail`,
	Args:    cobra.ExactArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		ref := args[0]

		client := newClient()
		result, err := client.CallTool("oauth", map[string]any{
			"action":        "status",
			"component_ref": ref,
		})
		if err != nil {
			handleToolError(err, "OAuth status failed")
		}
		if flagJSON {
			output.JSON(result)
			return
		}

		providers, _ := result["providers"].([]any)
		if len(providers) == 0 {
			fmt.Printf("%s declares no OAuth providers.\n", ref)
			return
		}
		fmt.Printf("OAuth status for %s:\n", ref)
		for _, p := range providers {
			pm, ok := p.(map[string]any)
			if !ok {
				continue
			}
			provider, _ := pm["provider"].(string)
			status, _ := pm["status"].(string)
			fmt.Printf("  %-12s %s\n", provider, status)
		}
	},
}

var oauthRevokeCmd = &cobra.Command{
	Use:     "revoke <ref> <provider>",
	Short:   "Revoke stored tokens for a component + provider",
	Example: `  cyfr oauth revoke c:local.gmail google`,
	Args:    cobra.ExactArgs(2),
	Run: func(cmd *cobra.Command, args []string) {
		ref := args[0]
		provider := args[1]

		client := newClient()
		toolArgs := map[string]any{
			"action":        "revoke",
			"component_ref": ref,
			"provider":      provider,
		}
		if oauthRevokePinVersion {
			toolArgs["pin_version"] = true
		}

		result, err := client.CallTool("oauth", toolArgs)
		if err != nil {
			handleToolError(err, "OAuth revoke failed")
		}
		if flagJSON {
			output.JSON(result)
			return
		}

		if msg, ok := result["message"].(string); ok {
			fmt.Printf("%s\n", msg)
		} else {
			fmt.Printf("Revoked %s for %s.\n", provider, ref)
		}
	},
}
