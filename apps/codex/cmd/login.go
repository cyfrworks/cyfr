// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"context"
	"errors"
	"fmt"
	"os"
	"slices"
	"strings"
	"time"

	"github.com/cyfr/codex/internal/config"
	"github.com/cyfr/codex/internal/mcp"
	"github.com/cyfr/codex/internal/ops"
	"github.com/cyfr/codex/internal/output"
	"github.com/cyfr/codex/internal/prompt"
	"github.com/spf13/cobra"
)

var flagLoginProvider string

func init() {
	loginCmd.Flags().StringVar(&flagLoginProvider, "provider", "",
		"Sign in with an OAuth provider's device flow instead of approving in Prism ("+
			strings.Join(ops.DeviceFlowProviders, " or ")+")")

	rootCmd.AddCommand(loginCmd)
	rootCmd.AddCommand(logoutCmd)
	rootCmd.AddCommand(whoamiCmd)
}

var loginCmd = &cobra.Command{
	Use:     "login",
	Short:   "Sign in by approving this command line in Prism",
	GroupID: "identity",
	Long: `Sign this command line in to the home by approving it in Prism.

cyfr login prints a link and a code, and waits. Open the link in a browser
signed in to the home, on this machine or another device: Prism asks you to
approve the command line on this machine and shows the code. Check that it
matches the one printed here, approve, and confirm with your passkey or a
fresh sign-in. The command line then holds a session of its own, listed
under Devices in Prism, where you can revoke it. The link signs in once and
expires in five minutes; Ctrl-C withdraws it.

On a machine where no one can approve it in Prism, --provider signs in with
GitHub or Google instead: the command line prints the provider's address and
a code, and receives its session once you enter the code there.

The session is saved under the context the command used: --context, or the
current one. A --url that is not that context's address saves nothing; add a
context for it first (cyfr context add <name> <url>). A context changed to
another address while the command waits keeps nothing: the sign-in is
withdrawn.`,
	Example: `  cyfr login
  cyfr login --context home
  cyfr login --provider google`,
	RunE: func(cmd *cobra.Command, args []string) error {
		target, err := sessionContext("save the session under")
		if err != nil {
			return err
		}

		if cmd.Flags().Changed("provider") && !slices.Contains(ops.DeviceFlowProviders, flagLoginProvider) {
			return fmt.Errorf("Unsupported provider %q — use '%s'.", flagLoginProvider,
				strings.Join(ops.DeviceFlowProviders, "' or '"))
		}

		// The client is the validated context's own: its address, from the
		// same read. Signing in is anonymous: a credential the context still
		// holds, revoked or expired, must not ride along and refuse it.
		client := clientAt(target.address, "")
		client.SessionID = ""

		// Confirm the server speaks a revision we understand before starting a
		// sign-in that would otherwise fail confusingly later.
		if err := client.Discover(cmd.Context()); err != nil {
			return fmt.Errorf("Failed to connect: %w", err)
		}

		if !cmd.Flags().Changed("provider") {
			return loginInPrism(cmd.Context(), client, target, machineName())
		}

		provider := flagLoginProvider
		// Start device flow
		result, err := client.CallTool(cmd.Context(), ops.Session, ops.SessionDeviceInitArgs{Provider: ops.Value(provider)})
		if err != nil {
			return fmt.Errorf("Failed to start login: %w", err)
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

		pollResult, err := pollDeviceAuth(cmd.Context(), client, provider, deviceCode,
			time.Duration(interval*float64(time.Second)), deadline, expiresIn, machineName())
		if err != nil {
			return err
		}

		// Save the session token as the credential of the context it was
		// signed in through.
		sessionID, _ := pollResult["session_token"].(string)
		if sessionID != "" {
			if err := saveSession(target, sessionID); errors.Is(err, errContextMoved) {
				// The context names another home now: the session is ended
				// at the home that issued it rather than kept under the
				// other's address.
				client.SessionID = sessionID
				if _, lerr := client.CallTool(cmd.Context(), ops.Session, ops.SessionLogoutArgs{}); lerr != nil {
					return fmt.Errorf("Signed in, but nothing was saved (%w), and the home could not end "+
						"the session (%v): it may still be active, so revoke the command line under "+
						"Devices in Prism", err, lerr)
				}
				return fmt.Errorf("Signed in, but the session was ended and nothing saved: %w", err)
			} else if err != nil {
				// Login already succeeded server-side; a failed local save
				// must say so or the next command's "not authenticated"
				// has no visible cause.
				fmt.Fprintf(os.Stderr, "warning: could not persist session locally: %v\n", err)
			}
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
		// fresh access_token. Fail so CI pipelines notice.
		if reauth, _ := pollResult["reauthenticate"].(bool); reauth {
			return errors.New("Login session expired during credential setup. " +
				"Please run `cyfr login` again.")
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
				return errors.New("cyfr.run requires policy acceptance but the server did not " +
					"return the access_token needed to record it. " +
					"Upgrade cyfr (server) and try again.")
			}

			if !runLegalAcceptInteractive(cmd.Context(), client, provider, accessToken) {
				return errors.New("Policy acceptance is required. Run `cyfr login` to try again.")
			}

			// Re-probe after policy acceptance to mint push tokens and store them
			// in the local CredentialStore.
			probeResult, perr := client.CallTool(cmd.Context(), ops.Registry, ops.RegistryProbeArgs{Provider: provider,
				AccessToken: accessToken})
			if perr != nil {
				return fmt.Errorf("Acceptance recorded but token refresh failed: %w\n"+
					"Please run `cyfr login` again.", perr)
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
				return errors.New("cyfr.run requires a personal namespace but the server " +
					"did not return the access_token needed to claim one. " +
					"Upgrade cyfr (server) and try again.")
			}

			if !promptAndClaimPersonalNamespace(cmd.Context(), client, provider, accessToken, suggested) {
				// User declined or exhausted retries — login is incomplete.
				return errors.New("Personal namespace claim is required. Run `cyfr login` to try again.")
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
		return nil
	},
}

// pollDeviceAuth polls until completion, expiry, denial, deadline or
// context cancellation. Transient network errors are retried.
func pollDeviceAuth(ctx context.Context, client *mcp.Client, provider, deviceCode string, interval time.Duration, deadline time.Time, expiresIn float64, machine string) (map[string]any, error) {
	for {
		if time.Now().After(deadline) {
			return nil, fmt.Errorf("Login timed out after %.0f seconds. Run `cyfr login` to try again.", expiresIn)
		}

		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(interval):
		}

		pollResult, err := client.CallTool(ctx, ops.Session, ops.SessionDevicePollArgs{DeviceCode: deviceCode,
			Provider: ops.Value(provider), Machine: ops.Value(machine)})
		if err != nil {
			if errors.Is(err, context.Canceled) {
				return nil, err
			}
			// Network errors etc — keep trying
			continue
		}

		status, _ := pollResult["status"].(string)
		switch status {
		case "complete":
			return pollResult, nil

		case "expired":
			return nil, errors.New("Device code expired. Run 'cyfr login' again.")

		case "denied":
			return nil, errors.New("Authorization denied.")

		case "registry_unavailable", "error":
			// A first sign-in needs cyfr.run once, to find or claim the
			// namespace that is this person's identity everywhere; the
			// server set nothing up and issued no session. Say so and
			// stop — the device code is one-shot.
			msg, _ := pollResult["message"].(string)
			if msg == "" {
				msg = "cyfr.run could not be reached. Run `cyfr login` again in a moment."
			}
			return nil, errors.New(msg)

		default:
			// "pending" or unknown — keep polling
		}
	}
}

// promptAndClaimPersonalNamespace prompts the user for a personal-namespace
// slug (default: `suggested`), then calls `registry.claim_personal` with the
// IdP `accessToken`. Returns true on success (and the access_token is
// discarded). On `slug_taken`, re-prompts up to 5 times. Returns false on
// user cancel, repeated slug_taken, or any unrecoverable error. The MCP
// tool surfaces errors as plain strings rather than structured codes, so
// this function inspects substrings of the error message to distinguish
// slug_taken from other failure modes.
func promptAndClaimPersonalNamespace(ctx context.Context, client *mcp.Client, provider, accessToken, suggested string) bool {
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

		args := ops.RegistryClaimPersonalArgs{Username: username,
			Provider:    provider,
			AccessToken: accessToken}

		result, err := client.CallTool(ctx, ops.Registry, args)
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
			if !runLegalAcceptInteractive(ctx, client, provider, accessToken) {
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
// This is the codex-CLI counterpart to the web flow's LegalAcceptController.
func runLegalAcceptInteractive(ctx context.Context, client *mcp.Client, provider, accessToken string) bool {
	if !prompt.IsInteractive(flagNoInteractive) {
		fmt.Fprintln(os.Stderr,
			"cyfr.run requires policy acceptance before claiming a namespace. "+
				"Re-run `cyfr login` in an interactive terminal to accept policies, "+
				"or accept via the web dashboard.")
		return false
	}

	verRaw, err := client.CallTool(ctx, ops.Registry, ops.RegistryLegalVersionArgs{})
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

		body, err := client.CallTool(ctx, ops.Registry, ops.RegistryLegalPageArgs{Name: name})
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

	_, err = client.CallTool(ctx, ops.Registry, ops.RegistryLegalAcceptArgs{Provider: provider,
		AccessToken:   ops.Value(accessToken),
		PolicyVersion: policyVersion})
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
	RunE: func(cmd *cobra.Command, args []string) error {
		// The session ended and the one cleared are the context's own, at
		// its own address: a --url that is not that address is refused
		// before anything is sent or cleared.
		target, err := sessionContext("log out of")
		if err != nil {
			return err
		}
		// The client is the validated context's own: its address and its
		// credential, from the same read.
		client := clientAt(target.address, target.token)

		// Clear saved session locally first — even if the server call fails
		// (e.g. session already expired), the user still wants local cleanup.
		// Only what the validating read found is cleared: a context set to
		// another address, or holding another session, since then is not
		// this logout's.
		if cfg, err := config.Load(); err == nil {
			if stored := cfg.Contexts[target.name]; stored != nil &&
				sameAddress(stored.URL, target.address) && stored.Token == target.token {
				stored.Token = ""
				if err := cfg.Save(); err != nil {
					fmt.Fprintf(os.Stderr, "warning: could not clear the saved session: %v\n", err)
				}
			}
		}

		result, err := client.CallTool(cmd.Context(), ops.Session, ops.SessionLogoutArgs{})
		if err != nil {
			// Session was already gone on the server — that's fine
			if flagJSON {
				output.JSON(map[string]any{"status": "logged_out"})
			} else {
				fmt.Println("Logged out successfully.")
			}
			return nil
		}

		if flagJSON {
			output.JSON(result)
		} else {
			fmt.Println("Logged out successfully.")
		}
		return nil
	},
}

// whoamiCmd is defined here for command grouping but lives next to the
// two-action compose logic in whoami.go.
