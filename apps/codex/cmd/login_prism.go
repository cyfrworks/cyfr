// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	"github.com/cyfr/codex/internal/config"
	"github.com/cyfr/codex/internal/mcp"
	"github.com/cyfr/codex/internal/ops"
	"github.com/cyfr/codex/internal/output"
	"github.com/cyfr/codex/internal/prompt"
)

// How long one poll, and the withdrawal of a sign-in this command line
// stops waiting for, may take: a home that hangs must not hold the command
// line past the link's expiry, nor past the person's Ctrl-C.
var (
	cliPollTimeout     = 10 * time.Second
	cliWithdrawTimeout = 3 * time.Second
)

// loginInPrism signs the command line in by its person's approval in
// Prism (Sanctum.CliSignIn on the home): it asks the home for a link and a
// code, prints them, and waits for the approval, the link's expiry or the
// person's Ctrl-C. Approved, it saves the session token the home answered
// at the start under the context target names, and says who signed in.
// Stopped any other way, it withdraws the sign-in, so an approval that
// lands later signs nothing in, or ends the session one that landed first
// minted.
func loginInPrism(ctx context.Context, client *mcp.Client, target, machine string) error {
	begun, err := client.CallTool(ctx, ops.Session, ops.SessionCliBeginArgs{Machine: machine})
	if err != nil {
		if errors.Is(err, context.Canceled) {
			return interrupted("Stopped before the home answered.")
		}
		return fmt.Errorf("Failed to start login: %w", err)
	}

	token, _ := begun["session_token"].(string)
	link, _ := begun["approve_url"].(string)
	code, _ := begun["user_code"].(string)
	if token == "" || link == "" {
		return errors.New("The home answered no approval link. Upgrade the home, " +
			"or sign in with cyfr login --provider github.")
	}
	interval := seconds(begun["interval"], 2)
	expiresIn := seconds(begun["expires_in"], 300)
	deadline := time.Now().Add(expiresIn)

	// The instructions are for the person; with --json they go to stderr,
	// so stdout carries the one JSON answer.
	var say io.Writer = os.Stdout
	if flagJSON {
		say = os.Stderr
	}
	fmt.Fprintf(say, "Approve the command line on %s in Prism:\n\n  %s\n\n", machine, link)
	fmt.Fprintf(say, "Check that Prism shows the code %s.\n", code)
	fmt.Fprintf(say, "Waiting for approval; the link expires in %d minutes. Ctrl-C stops.\n",
		int(expiresIn.Round(time.Minute)/time.Minute))
	fmt.Fprintln(say, "Not signed in to Prism there? Sign in, then open the link again. "+
		"No one to approve it? Run cyfr login --provider github.")

	status, err := pollCliSignIn(ctx, client, token, interval, deadline)
	switch {
	case errors.Is(err, context.Canceled):
		withdraw(client, token)
		return interrupted("Stopped waiting; the sign-in was withdrawn.")
	case err != nil:
		withdraw(client, token)
		return err
	}

	switch status {
	case "approved":
	case "revoked":
		return errors.New("The sign-in was revoked in Prism before this command line received it. " +
			"Run cyfr login again.")
	case "cancelled":
		return errors.New("The sign-in was withdrawn. Run cyfr login again.")
	default:
		return errLinkExpired
	}

	if err := saveSession(target, token); err != nil {
		// The home signed the command line in; a session this machine
		// cannot keep is withdrawn rather than left signed in, unheld.
		withdraw(client, token)
		return fmt.Errorf("Approved, but the session could not be saved here, so it was withdrawn: %w", err)
	}

	client.SessionID = token
	who, err := client.CallTool(ctx, ops.Session, ops.SessionWhoamiArgs{})
	email, _ := who["email"].(string)
	if flagJSON {
		output.JSON(map[string]any{"status": "approved", "machine": machine, "context": target,
			"email": email})
		return nil
	}
	switch {
	case err == nil && email != "":
		fmt.Printf("Signed in as %s.\n", email)
	default:
		fmt.Println("Signed in.")
	}
	return nil
}

// errLinkExpired is the command line's own deadline, the link's expiry,
// passing while the home last answered that it waits.
var errLinkExpired = errors.New("The link expired before it was approved. Run cyfr login again.")

// pollCliSignIn asks the home what became of the sign-in every interval
// until it is approved, expired, withdrawn or revoked, the deadline passes
// or ctx ends, and answers that status. A poll the home does not answer is
// tried again until the deadline, which then says the home could not be
// reached rather than that the link expired.
func pollCliSignIn(ctx context.Context, client *mcp.Client, token string, interval time.Duration, deadline time.Time) (string, error) {
	var unreachable error
	for {
		if !time.Now().Before(deadline) {
			if unreachable != nil {
				return "", fmt.Errorf("Could not reach the home to learn whether the command line "+
					"was approved (%v), and the link has expired. Run cyfr login again.", unreachable)
			}
			return "", errLinkExpired
		}

		select {
		case <-ctx.Done():
			return "", ctx.Err()
		case <-time.After(interval):
		}

		pollCtx, cancel := context.WithTimeout(ctx, cliPollTimeout)
		result, err := client.CallTool(pollCtx, ops.Session, ops.SessionCliPollArgs{SessionToken: token})
		cancel()
		if err != nil {
			if ctx.Err() != nil {
				return "", ctx.Err()
			}
			unreachable = err
			continue
		}
		unreachable = nil

		switch status, _ := result["status"].(string); status {
		case "approved", "expired", "cancelled", "revoked":
			return status, nil
		}
	}
}

// withdraw tells the home this command line stopped waiting, within a
// bound of its own since the command's context may already have ended.
// A home it cannot tell is said so: the person then revokes under
// Devices whatever an approval signed in.
func withdraw(client *mcp.Client, token string) {
	ctx, cancel := context.WithTimeout(context.Background(), cliWithdrawTimeout)
	defer cancel()
	if _, err := client.CallTool(ctx, ops.Session, ops.SessionCliCancelArgs{SessionToken: token}); err != nil {
		fmt.Fprintf(os.Stderr, "The home could not be told the command line stopped waiting (%v). "+
			"If the link is approved before it expires, revoke the command line under Devices in Prism.\n", err)
	}
}

// interrupted is the person's own Ctrl-C (or the terminal closing): said
// on stderr, then exited with 130 and nothing more printed.
func interrupted(sentence string) error {
	fmt.Fprintln(os.Stderr, sentence)
	return prompt.ErrAborted
}

// seconds reads a whole number of seconds a home answered, or fallback.
func seconds(value any, fallback float64) time.Duration {
	n, ok := value.(float64)
	if !ok || n <= 0 {
		n = fallback
	}
	return time.Duration(n * float64(time.Second))
}

// machineName is this machine's host name as the home takes it: printable
// ASCII, at most 64 bytes, and "unknown" when none is left.
func machineName() string {
	host, _ := os.Hostname()
	var name strings.Builder
	for _, r := range host {
		if r >= 0x20 && r <= 0x7e && name.Len() < 64 {
			name.WriteRune(r)
		}
	}
	if trimmed := strings.TrimSpace(name.String()); trimmed != "" {
		return trimmed
	}
	return "unknown"
}

// loginContext names the stored context a login saves its session under:
// --context, or the current one. A context that does not exist, or a --url
// that is not its address, is refused before anything is asked of a home,
// since a session saved under another home's context would be sent there
// with every later command.
func loginContext() (string, error) {
	cfg, err := config.Load()
	if err != nil {
		return "", fmt.Errorf("Could not read the command line's config: %w", err)
	}
	name := contextName(cfg)
	stored := cfg.Contexts[name]
	if stored == nil {
		return "", fmt.Errorf("No context named %q to save the session under: add it with "+
			"cyfr context add %s <url>.", name, name)
	}
	if flagURL != "" && !sameAddress(flagURL, stored.URL) {
		return "", fmt.Errorf("--url %s is not the address of the context %q (%s), so login "+
			"would save that home's session under this one. Add a context for it "+
			"(cyfr context add <name> %s), then run cyfr login --context <name>.",
			flagURL, name, stored.URL, flagURL)
	}
	return name, nil
}

// sameAddress is whether two addresses name one home, a trailing slash and
// the case of the scheme and host aside.
func sameAddress(a, b string) bool {
	return strings.EqualFold(strings.TrimRight(a, "/"), strings.TrimRight(b, "/"))
}

// saveSession stores token as the credential of the context name.
func saveSession(name, token string) error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}
	stored := cfg.Contexts[name]
	if stored == nil {
		return fmt.Errorf("the context %q is gone", name)
	}
	stored.Token = token
	return cfg.Save()
}
