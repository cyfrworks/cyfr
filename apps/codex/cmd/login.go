package cmd

import (
	"fmt"
	"os"
	"time"

	"github.com/cyfr/codex/internal/config"
	"github.com/cyfr/codex/internal/mcp"
	"github.com/cyfr/codex/internal/output"
	"github.com/cyfr/codex/internal/prompt"
	"github.com/spf13/cobra"
)

var flagLoginProvider string

func init() {
	loginCmd.Flags().StringVar(&flagLoginProvider, "provider", "github",
		"OAuth provider for device-flow login (github or google)")

	rootCmd.AddCommand(loginCmd)
	rootCmd.AddCommand(logoutCmd)
	rootCmd.AddCommand(whoamiCmd)
}

var loginCmd = &cobra.Command{
	Use:     "login",
	Short:   "Authenticate via Device Flow",
	GroupID: "identity",
	Long: `Start an OAuth 2.0 Device Authorization Flow via GitHub or Google.

The CLI prints a one-time code and a verification URL; open the URL in a
browser, enter the code, and the CLI will receive a session token
automatically. On first login (or when this machine hasn't probed cyfr.run
for push tokens yet), the CLI will also prompt you to claim a personal
namespace on cyfr.run — required before you can push components.`,
	Example: `  cyfr login
  cyfr login --provider google`,
	Run: func(cmd *cobra.Command, args []string) {
		provider := flagLoginProvider

		// When the user didn't explicitly pass --provider and we're attached
		// to a TTY, offer a picker instead of silently defaulting to GitHub.
		// This keeps shell scripts deterministic (flag or --no-interactive
		// ⇒ no prompt) while making Google discoverable interactively.
		if !cmd.Flags().Changed("provider") && prompt.IsInteractive(flagNoInteractive) {
			choice, err := prompt.SelectOne("Choose an OAuth provider", []prompt.Option{
				{Label: "GitHub", Value: "github"},
				{Label: "Google", Value: "google"},
			})
			if err != nil {
				output.Errorf("Provider selection cancelled: %v", err)
			}
			provider = choice
		}

		if provider != "github" && provider != "google" {
			output.Errorf("Unsupported provider %q — use 'github' or 'google'.", provider)
		}

		client := newClient()

		// Confirm the server speaks a revision we understand before starting a
		// device flow that would otherwise fail confusingly later.
		if err := client.Discover(); err != nil {
			output.Errorf("Failed to connect: %v", err)
		}

		// Start device flow
		result, err := client.CallTool("session", map[string]any{
			"action":   "device_init",
			"provider": provider,
		})
		if err != nil {
			output.Errorf("Failed to start login: %v", err)
		}

		// Show user code and verification URL
		userCode, _ := result["user_code"].(string)
		verifyURL, _ := result["verification_uri"].(string)
		deviceCode, _ := result["device_code"].(string)
		interval, _ := result["interval"].(float64)
		if interval < 5 {
			interval = 5
		}

		// Bound the polling loop so a never-authorized device code can't block
		// the CLI forever. Honor the server's expiry when provided, else the
		// OAuth device-flow norm of 15 minutes.
		expiresIn, _ := result["expires_in"].(float64)
		if expiresIn <= 0 {
			expiresIn = 900
		}
		// Multiply before the Duration cast so a fractional expires_in isn't
		// truncated to nanoseconds.
		deadline := time.Now().Add(time.Duration(expiresIn * float64(time.Second)))

		fmt.Printf("Open %s and enter code: %s\n", verifyURL, userCode)
		fmt.Println("Waiting for authorization...")

		// Poll for completion
		for {
			if time.Now().After(deadline) {
				output.Errorf("Login timed out after %.0f seconds. Run `cyfr login` to try again.", expiresIn)
			}

			time.Sleep(time.Duration(interval) * time.Second)

			pollResult, err := client.CallTool("session", map[string]any{
				"action":      "device_poll",
				"device_code": deviceCode,
				"provider":    provider,
			})
			if err != nil {
				// Network errors etc — keep trying
				continue
			}

			status, _ := pollResult["status"].(string)
			switch status {
			case "complete":
				// Save session ID from the auth response
				sessionID, _ := pollResult["session_id"].(string)
				cfg, _ := config.Load()
				if cfg.Current() != nil {
					if sessionID != "" {
						cfg.Current().SessionID = sessionID
					} else if client.SessionID != "" {
						cfg.Current().SessionID = client.SessionID
					}
					_ = cfg.Save()
				}

				// Swap the in-flight MCP client onto the newly issued Sanctum
				// session token. Subsequent calls in this process (notably
				// `registry.claim_personal`) then arrive with an authenticated
				// context, which the server uses to persist the returned push
				// token to CredentialStore. Without this swap, claim_personal
				// rides with the unauthenticated bootstrap MCP session and
				// the token is never cached locally.
				if sessionID != "" {
					client.SessionID = sessionID
				}

				if user, ok := pollResult["user"].(map[string]any); ok {
					email, _ := user["email"].(string)
					if email != "" {
						fmt.Printf("Logged in as %s\n", email)
					} else {
						fmt.Println("Logged in successfully!")
					}
				} else {
					fmt.Println("Logged in successfully!")
				}

				// `reauthenticate: true` — IdP access_token was rejected by
				// cyfr.run's probe. The device_code is one-shot so there's no
				// retry path; the user must run `cyfr login` again to mint a
				// fresh access_token. Exit non-zero so CI pipelines notice.
				if reauth, _ := pollResult["reauthenticate"].(bool); reauth {
					fmt.Fprintln(os.Stderr,
						"Login session expired during credential setup. "+
							"Please run `cyfr login` again.")
					os.Exit(1)
				}

				// Probe-gate: cyfr.run requires acceptance of the current
				// bundled policy_version before any push-token mint. If the
				// server returned `needs_policy_acceptance: true`, render the
				// policies in the terminal, capture y/n per doc, then call
				// registry.legal_accept and re-probe via registry.probe (which
				// stores credentials too). After re-probe, fall through to the
				// existing needs_personal_namespace handler if applicable.
				if needsPolicyAccept, _ := pollResult["needs_policy_acceptance"].(bool); needsPolicyAccept {
					accessToken, _ := pollResult["access_token"].(string)
					if accessToken == "" {
						fmt.Fprintln(os.Stderr,
							"cyfr.run requires policy acceptance but the server did not "+
								"return the access_token needed to record it. "+
								"Upgrade cyfr (server) and try again.")
						os.Exit(1)
					}

					if !runLegalAcceptInteractive(client, provider, accessToken) {
						fmt.Fprintln(os.Stderr,
							"Policy acceptance is required. Run `cyfr login` to try again.")
						os.Exit(1)
					}

					// Re-probe to mint push tokens now that the gate passes.
					// MCP `registry.probe` writes credentials to the local
					// CredentialStore for authenticated callers, so a single
					// call replaces what session.device_poll's internal probe
					// would have done if acceptance had been current.
					probeResult, perr := client.CallTool("registry", map[string]any{
						"action":       "probe",
						"provider":     provider,
						"access_token": accessToken,
					})
					if perr != nil {
						fmt.Fprintf(os.Stderr,
							"Acceptance recorded but token refresh failed: %v\n"+
								"Please run `cyfr login` again.\n", perr)
						os.Exit(1)
					}

					// Update the poll-result-derived view so the existing
					// downstream handlers see the post-accept state. probe
					// returns {personal_namespace, memberships}; absent
					// personal_namespace means the user still needs to claim
					// (handled by the existing block below).
					if pn, _ := probeResult["personal_namespace"].(map[string]any); pn != nil {
						pollResult["personal_namespace"] = pn
						pollResult["needs_personal_namespace"] = false
					} else {
						pollResult["needs_personal_namespace"] = true
						pollResult["access_token"] = accessToken
					}
				}

				// If cyfr.run reports no personal namespace, prompt the user
				// to claim one. This is a one-time choice per identity.
				if needs, _ := pollResult["needs_personal_namespace"].(bool); needs {
					accessToken, _ := pollResult["access_token"].(string)
					suggested, _ := pollResult["suggested_username"].(string)

					if accessToken == "" {
						// Server-side Option X: access_token should be present
						// whenever needs_personal_namespace is true. If it isn't,
						// the server/client versions are mismatched — fail loud.
						fmt.Fprintln(os.Stderr,
							"cyfr.run requires a personal namespace but the server "+
								"did not return the access_token needed to claim one. "+
								"Upgrade cyfr (server) and try again.")
						os.Exit(1)
					}

					if !promptAndClaimPersonalNamespace(client, provider, accessToken, suggested) {
						// User declined or exhausted retries — login is incomplete.
						fmt.Fprintln(os.Stderr,
							"Personal namespace claim is required. Run `cyfr login` to try again.")
						os.Exit(1)
					}
				}

				// Credential-store warnings: push tokens were issued by cyfr.run
				// but couldn't be cached locally. The user's session is still
				// valid; they should re-run `cyfr whoami` once connectivity is
				// restored to retry storage.
				if warns, ok := pollResult["credential_store_warnings"].([]any); ok && len(warns) > 0 {
					slugs := make([]string, 0, len(warns))
					for _, w := range warns {
						if s, ok := w.(string); ok {
							slugs = append(slugs, s)
						}
					}
					fmt.Fprintf(os.Stderr,
						"Warning: could not cache push tokens for namespaces: %v. "+
							"Run `cyfr whoami` later to retry.\n", slugs)
				}

				// Probe error (transient, non-reauthenticate). Session is
				// valid; user may need to retry via `cyfr whoami` auto-probe.
				if probeErr, _ := pollResult["probe_error"].(string); probeErr != "" {
					fmt.Fprintf(os.Stderr,
						"Warning: cyfr.run identity probe failed (%s). "+
							"Run `cyfr whoami` to retry.\n", probeErr)
				}

				if flagJSON {
					output.JSON(pollResult)
				}
				return

			case "expired":
				output.Error("Device code expired. Run 'cyfr login' again.")

			case "denied":
				output.Error("Authorization denied.")

			default:
				// "pending" or unknown — keep polling
				continue
			}
		}
	},
}

// promptAndClaimPersonalNamespace prompts the user for a personal-namespace
// slug (default: `suggested`), then calls `registry.claim_personal` with the
// IdP `accessToken`. Returns true on success (and the access_token is
// discarded). On `slug_taken`, re-prompts up to 5 times. Returns false on
// user cancel, repeated slug_taken, or any unrecoverable error. The MCP
// tool surfaces errors as plain strings rather than structured codes, so
// this function inspects substrings of the error message to distinguish
// slug_taken from other failure modes.
func promptAndClaimPersonalNamespace(client *mcp.Client, provider, accessToken, suggested string) bool {
	if !prompt.IsInteractive(flagNoInteractive) {
		fmt.Fprintln(os.Stderr,
			"cyfr.run requires a personal namespace claim on first login. "+
				"Re-run `cyfr login` in an interactive terminal to claim one, "+
				"or pre-claim via the web dashboard at /claim-namespace.")
		return false
	}

	fmt.Println()
	fmt.Println("Claim your personal namespace on cyfr.run.")
	fmt.Println("Personal slugs are lowercase alphanumerics with single hyphens, " +
		"1-39 chars (GitHub-style). This is a one-time choice per identity.")

	defaultSlug := suggested

	for attempt := 1; attempt <= 5; attempt++ {
		username, err := prompt.InputText("Personal namespace", defaultSlug)
		if err != nil {
			if prompt.IsAborted(err) {
				return false
			}
			fmt.Fprintf(os.Stderr, "Prompt failed: %v\n", err)
			return false
		}

		if username == "" {
			fmt.Fprintln(os.Stderr, "Slug cannot be empty.")
			continue
		}

		args := map[string]any{
			"action":       "claim_personal",
			"username":     username,
			"provider":     provider,
			"access_token": accessToken,
		}

		result, err := client.CallTool("registry", args)
		if err == nil {
			if slug, ok := result["slug"].(string); ok {
				fmt.Printf("Claimed personal namespace: %s\n", slug)
			} else {
				fmt.Printf("Claimed personal namespace: %s\n", username)
			}
			return true
		}

		msg := err.Error()
		switch {
		case containsFold(msg, "slug_taken") || containsFold(msg, "already taken"):
			fmt.Fprintf(os.Stderr, "'%s' is already taken. Try a different slug.\n", username)
			// Don't re-use the taken default on the next prompt.
			defaultSlug = ""
			continue

		case containsFold(msg, "already_claimed"):
			// Rare: user already has a personal namespace but it wasn't in
			// the probe response for some reason. Treat as success — their
			// next `cyfr whoami` probe will pick it up.
			fmt.Println("Your account already has a personal namespace on cyfr.run. " +
				"Run `cyfr whoami` to see it.")
			return true

		case containsFold(msg, "invalid_username") || containsFold(msg, "INVALID_USERNAME"):
			fmt.Fprintf(os.Stderr,
				"'%s' is not a valid personal slug. Must be bare lowercase "+
					"alphanumerics + single hyphens (1-39 chars), no '@'.\n", username)
			defaultSlug = ""
			continue

		case containsFold(msg, "reserved"):
			fmt.Fprintf(os.Stderr,
				"'%s' is reserved by cyfr.run. Try a different slug.\n", username)
			defaultSlug = ""
			continue

		case containsFold(msg, "invalid_access_token"):
			// IdP token expired between poll and claim — CLI can't recover
			// without a fresh device flow.
			fmt.Fprintln(os.Stderr,
				"Login session expired during namespace claim. "+
					"Please run `cyfr login` again.")
			return false

		case containsFold(msg, "policy_acceptance_required") ||
			containsFold(msg, "POLICY_ACCEPTANCE_REQUIRED"):
			// cyfr.run requires clickwrap acceptance of the current bundled
			// policy_version before any namespace claim. Render the policies
			// in the terminal, prompt y/n per doc, then call
			// registry.legal_accept and loop back to retry the claim with
			// the same access_token.
			if !runLegalAcceptInteractive(client, provider, accessToken) {
				return false
			}
			// Don't mark this attempt against the 5-attempt budget — the
			// user just spent time reading policies; they get the same
			// chance to type a slug they had before.
			defaultSlug = username
			continue

		default:
			fmt.Fprintf(os.Stderr, "Claim failed: %v\n", err)
			return false
		}
	}

	fmt.Fprintln(os.Stderr, "Too many attempts. Run `cyfr login` again when you have a slug in mind.")
	return false
}

// runLegalAcceptInteractive renders each bundled policy in the terminal
// and prompts the user to acknowledge each one before calling
// registry.legal_accept. Returns true on success (acceptance recorded);
// false if the user bails or any step fails.
//
// This is the codex-CLI counterpart to the prism web flow's
// LegalAcceptController and the porta UI's LegalAcceptPage.
func runLegalAcceptInteractive(client *mcp.Client, provider, accessToken string) bool {
	if !prompt.IsInteractive(flagNoInteractive) {
		fmt.Fprintln(os.Stderr,
			"cyfr.run requires policy acceptance before claiming a namespace. "+
				"Re-run `cyfr login` in an interactive terminal to accept policies, "+
				"or accept via the web dashboard.")
		return false
	}

	verRaw, err := client.CallTool("registry", map[string]any{
		"action": "legal_version",
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "Couldn't fetch current policy version: %v\n", err)
		return false
	}

	policyVersion, _ := verRaw["policy_version"].(string)
	if policyVersion == "" {
		fmt.Fprintln(os.Stderr, "cyfr.run returned an empty policy version; aborting.")
		return false
	}

	policies, _ := verRaw["policies"].([]any)
	if len(policies) == 0 {
		fmt.Fprintln(os.Stderr, "cyfr.run returned no policies; aborting.")
		return false
	}

	fmt.Println()
	fmt.Println("─── Accept policies ───")
	fmt.Printf("Policy bundle: %s\n", policyVersion)
	fmt.Printf("%d documents to review.\n\n", len(policies))

	for _, raw := range policies {
		entry, ok := raw.(map[string]any)
		if !ok {
			continue
		}
		name, _ := entry["name"].(string)
		title, _ := entry["title"].(string)
		if name == "" {
			continue
		}

		body, err := client.CallTool("registry", map[string]any{
			"action": "legal_page",
			"name":   name,
		})
		if err != nil {
			fmt.Fprintf(os.Stderr, "Couldn't fetch '%s': %v\n", name, err)
			return false
		}

		md, _ := body["content_markdown"].(string)
		fmt.Println()
		fmt.Printf("══════ %s ══════\n", title)
		fmt.Println()
		fmt.Println(md)
		fmt.Println()

		ok2, err := prompt.Confirm(fmt.Sprintf("I have read and agree to the %s.", title))
		if err != nil {
			if prompt.IsAborted(err) {
				fmt.Fprintln(os.Stderr, "Acceptance aborted.")
			} else {
				fmt.Fprintf(os.Stderr, "Prompt failed: %v\n", err)
			}
			return false
		}
		if !ok2 {
			fmt.Fprintln(os.Stderr,
				"You must accept all policies to claim a namespace on cyfr.run.")
			return false
		}
	}

	_, err = client.CallTool("registry", map[string]any{
		"action":         "legal_accept",
		"provider":       provider,
		"access_token":   accessToken,
		"policy_version": policyVersion,
	})
	if err != nil {
		msg := err.Error()
		switch {
		case containsFold(msg, "policy_version_mismatch"):
			fmt.Fprintln(os.Stderr,
				"Policies were updated while you were reading. "+
					"Re-run `cyfr login` to accept the new version.")
		case containsFold(msg, "invalid_access_token"):
			fmt.Fprintln(os.Stderr,
				"Login session expired. Please run `cyfr login` again.")
		case containsFold(msg, "IDENTITY_BANNED"):
			fmt.Fprintln(os.Stderr,
				"This identity is currently restricted from publishing on cyfr.run.")
		default:
			fmt.Fprintf(os.Stderr, "Acceptance failed: %v\n", err)
		}
		return false
	}

	fmt.Printf("\nAcceptance recorded (policy_version=%s).\n\n", policyVersion)
	return true
}

// containsFold is a case-insensitive substring check. Inlined to avoid
// pulling in strings in a file that doesn't otherwise use it.
func containsFold(haystack, needle string) bool {
	hl := len(haystack)
	nl := len(needle)
	if nl > hl {
		return false
	}
	for i := 0; i+nl <= hl; i++ {
		if eqFold(haystack[i:i+nl], needle) {
			return true
		}
	}
	return false
}

func eqFold(a, b string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := 0; i < len(a); i++ {
		ca, cb := a[i], b[i]
		if ca >= 'A' && ca <= 'Z' {
			ca += 32
		}
		if cb >= 'A' && cb <= 'Z' {
			cb += 32
		}
		if ca != cb {
			return false
		}
	}
	return true
}

var logoutCmd = &cobra.Command{
	Use:     "logout",
	Short:   "End current session",
	GroupID: "identity",
	Long:    "Invalidate the current session on the server and remove the cached session token from local config.",
	Example: "  cyfr logout",
	Run: func(cmd *cobra.Command, args []string) {
		client := newClient()

		// Clear saved session locally first — even if the server call fails
		// (e.g. session already expired), the user still wants local cleanup.
		cfg, _ := config.Load()
		if cfg.Current() != nil {
			cfg.Current().SessionID = ""
			_ = cfg.Save()
		}

		result, err := client.CallTool("session", map[string]any{
			"action": "logout",
		})
		if err != nil {
			// Session was already gone on the server — that's fine
			if flagJSON {
				output.JSON(map[string]any{"status": "logged_out"})
			} else {
				fmt.Println("Logged out successfully.")
			}
			return
		}

		if flagJSON {
			output.JSON(result)
		} else {
			fmt.Println("Logged out successfully.")
		}
	},
}

// whoamiCmd is defined here for command grouping but lives next to the
// two-action compose logic in whoami.go.
