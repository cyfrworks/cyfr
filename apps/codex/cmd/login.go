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
namespace on cyfr.run — required before you can publish components.`,
	Example: `  cyfr login
  cyfr login --provider google`,
	Run: func(cmd *cobra.Command, args []string) {
		provider := flagLoginProvider
		if provider != "github" && provider != "google" {
			output.Errorf("Unsupported provider %q — use 'github' or 'google'.", provider)
		}

		client := newClient()

		// Initialize MCP session
		if err := client.Initialize(); err != nil {
			output.Errorf("Failed to connect: %v", err)
		}

		// Start device flow
		result, err := client.CallTool("session", map[string]any{
			"action":   "device-init",
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

		fmt.Printf("Open %s and enter code: %s\n", verifyURL, userCode)
		fmt.Println("Waiting for authorization...")

		// Poll for completion
		for {
			time.Sleep(time.Duration(interval) * time.Second)

			pollResult, err := client.CallTool("session", map[string]any{
				"action":      "device-poll",
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
// slug (default: `suggested`), then calls `registry.claim-personal` with the
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
			"action":       "claim-personal",
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

		default:
			fmt.Fprintf(os.Stderr, "Claim failed: %v\n", err)
			return false
		}
	}

	fmt.Fprintln(os.Stderr, "Too many attempts. Run `cyfr login` again when you have a slug in mind.")
	return false
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
