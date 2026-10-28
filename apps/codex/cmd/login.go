// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"net/url"
	"os"
	"slices"
	"strings"
	"time"

	"github.com/cyfr/codex/internal/access"
	"github.com/cyfr/codex/internal/config"
	"github.com/cyfr/codex/internal/mcp"
	"github.com/cyfr/codex/internal/ops"
	"github.com/cyfr/codex/internal/output"
	"github.com/spf13/cobra"
)

var (
	flagLoginProvider string
	flagLoginSetup    bool
)

func init() {
	loginCmd.Flags().StringVar(&flagLoginProvider, "provider", "",
		"Sign in with an OAuth provider's device flow instead of approving in Prism ("+
			strings.Join(ops.DeviceFlowProviders, " or ")+")")
	loginCmd.Flags().BoolVar(&flagLoginSetup, "setup", false,
		"Sign in as this CYFR's first person with CYFR_SETUP_TOKEN from .env in this directory, setting them up the first time (a headless CYFR)")

	rootCmd.AddCommand(loginCmd)
	rootCmd.AddCommand(logoutCmd)
	rootCmd.AddCommand(whoamiCmd)
}

var loginCmd = &cobra.Command{
	Use:     "login",
	Short:   "Sign in by approving this command line in Prism",
	GroupID: "identity",
	Long: `Sign this command line in to CYFR by approving it in Prism.

cyfr login prints a link and a code, and waits. Open the link in a browser
signed in to CYFR, on this machine or another device: Prism asks you to
approve the command line on this machine and shows the code. Check that it
matches the one printed here, approve, and confirm with your passkey or a
fresh sign-in. The command line then holds a session of its own, listed
under Devices in Prism, where you can revoke it. The link signs in once and
expires in five minutes; Ctrl-C withdraws it.

On a machine where no one can approve it in Prism, --provider signs in with
GitHub or Google instead: the command line prints the provider's address and
a code, and receives its session once you enter the code there.

A headless CYFR (CYFR_HEADLESS=on) serves no setup page, so --setup sets up
its first person, who administers it: run in the directory cyfr init set
up, it reads CYFR_SETUP_TOKEN from .env there and signs the command line in
as that person. Run again, it signs the same person in again, until they
have a passkey, a device they connected or a sign-in method they linked;
from then on the token opens nothing, and the command line signs in with
cyfr login.

The session is saved under the context the command used: --context, or the
current one. A --url that is not that context's address saves nothing; add a
context for it first (cyfr context add <name> <url>). A context changed to
another address while the command waits keeps nothing: the sign-in is
withdrawn.`,
	Example: `  cyfr login
  cyfr login --context work
  cyfr login --provider google
  cyfr login --setup`,
	RunE: func(cmd *cobra.Command, args []string) error {
		if flagLoginSetup && cmd.Flags().Changed("provider") {
			return errors.New("--setup signs in with this CYFR's setup token and --provider with a provider: use one of them.")
		}
		target, err := sessionContext("save the session under")
		if err != nil {
			return err
		}

		if cmd.Flags().Changed("provider") && !slices.Contains(ops.DeviceFlowProviders, flagLoginProvider) {
			return fmt.Errorf("Unsupported provider %q — use '%s'.", flagLoginProvider,
				strings.Join(ops.DeviceFlowProviders, "' or '"))
		}

		var setupToken string
		if flagLoginSetup {
			if setupToken, err = setupTokenHere(); err != nil {
				return err
			}
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

		if flagLoginSetup {
			return loginWithSetup(cmd.Context(), client, target, setupToken, machineName())
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
			if err := keepSession(cmd.Context(), client, target, sessionID); err != nil {
				return err
			}
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

		if flagJSON {
			output.JSON(pollResult)
		}
		return nil
	},
}

// keepSession saves sessionID, the session CYFR signed the command line in
// with, as the credential of the context target names (saveSession).
func keepSession(ctx context.Context, client *mcp.Client, target storedContext, sessionID string) error {
	if err := saveSession(target, sessionID); errors.Is(err, errContextMoved) {
		// The context names another CYFR now: the session is ended at the
		// CYFR that issued it rather than kept under the other's address.
		client.SessionID = sessionID
		if _, lerr := client.CallTool(ctx, ops.Session, ops.SessionLogoutArgs{}); lerr != nil {
			return fmt.Errorf("Signed in, but nothing was saved (%w), and CYFR could not end "+
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
	return nil
}

// setupTokenHere is CYFR_SETUP_TOKEN as the .env in the working directory
// assigns it, trimmed as the server reads it. No .env, or no token in it,
// is refused naming .env.
func setupTokenHere() (string, error) {
	values, err := access.ReadEnvValues(".env")
	if errors.Is(err, fs.ErrNotExist) {
		return "", errors.New("There is no .env here, so no CYFR_SETUP_TOKEN: run cyfr login --setup in the directory cyfr init set up.")
	}
	if err != nil {
		return "", fmt.Errorf("Could not read .env here: %w", engineFailure(err))
	}
	token := strings.TrimSpace(values[setupTokenVar])
	if token == "" {
		return "", errors.New("There is no CYFR_SETUP_TOKEN in .env here: run cyfr login --setup in the directory cyfr init set up.")
	}
	return token, nil
}

// loginWithSetup signs the command line in as this CYFR's first person
// with its setup token (session.setup): the person is made by the first
// call, and signed in again by each later one while they hold no passkey,
// no device they connected and no sign-in method they linked. The session
// is kept as the device flow keeps one.
func loginWithSetup(ctx context.Context, client *mcp.Client, target storedContext, token, machine string) error {
	answer, err := client.CallTool(ctx, ops.Session, ops.SessionSetupArgs{SetupToken: token, Machine: machine})
	switch {
	case errors.Is(err, context.Canceled):
		return interrupted("Stopped before CYFR answered.")
	case errors.As(err, new(*url.Error)):
		return fmt.Errorf("Failed to set up: %w", err)
	case err != nil:
		// The answer carries the refusal's sentence alone, so the way in
		// once the setup token opens nothing is said beside any refusal.
		return fmt.Errorf("%w\nOnce this CYFR's first person has a passkey, a device they connected or "+
			"a sign-in method they linked, this command line signs in with cyfr login.", err)
	}

	sessionID, _ := answer["session_token"].(string)
	if sessionID == "" {
		return errors.New("CYFR answered no session, so nothing was saved. Run cyfr login --setup again.")
	}
	if err := keepSession(ctx, client, target, sessionID); err != nil {
		return err
	}

	readmitted, _ := answer["readmitted"].(bool)
	if flagJSON {
		output.JSON(map[string]any{"status": "signed_in", "context": target.name,
			"user_id": answer["user_id"], "readmitted": readmitted})
		return nil
	}
	if readmitted {
		fmt.Println("Signed in again as this CYFR's first person.")
	} else {
		fmt.Println("Signed in as this CYFR's first person.")
	}
	return nil
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

		case "error":
			// The server issued no session and says why; the device code
			// is one-shot, so stop.
			msg, _ := pollResult["message"].(string)
			if msg == "" {
				msg = "The sign-in did not complete. Run `cyfr login` again in a moment."
			}
			return nil, errors.New(msg)

		default:
			// "pending" or unknown — keep polling
		}
	}
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
