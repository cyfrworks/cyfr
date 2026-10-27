// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/url"
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
func loginInPrism(ctx context.Context, client *mcp.Client, target storedContext, machine string) error {
	begun, err := client.CallTool(ctx, ops.Session, ops.SessionCliBeginArgs{Machine: machine})
	if err != nil {
		if errors.Is(err, context.Canceled) {
			return interrupted("Stopped before CYFR answered.")
		}
		return fmt.Errorf("Failed to start login: %w", err)
	}

	token, _ := begun["session_token"].(string)
	link, _ := begun["approve_url"].(string)
	code, _ := begun["user_code"].(string)
	if token == "" || link == "" {
		return errors.New("CYFR answered no approval link. Upgrade CYFR, " +
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
		if werr := withdraw(client, token); werr != nil {
			unwithdrawn(werr)
			return interrupted("Stopped waiting.")
		}
		return interrupted("Stopped waiting; the sign-in was withdrawn.")
	case err != nil:
		if werr := withdraw(client, token); werr != nil {
			unwithdrawn(werr)
		}
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
		// cannot keep, or would keep under another home's address, is
		// withdrawn rather than left signed in, unheld.
		if werr := withdraw(client, token); werr != nil {
			return fmt.Errorf("Approved, but the session could not be saved here (%w), and CYFR "+
				"could not be told to end it (%v): it may still be active, so revoke the command line "+
				"under Devices in Prism", err, werr)
		}
		return fmt.Errorf("Approved, but the session could not be saved here, so it was withdrawn: %w", err)
	}

	client.SessionID = token
	who, err := client.CallTool(ctx, ops.Session, ops.SessionWhoamiArgs{})
	email, _ := who["email"].(string)
	if flagJSON {
		output.JSON(map[string]any{"status": "approved", "machine": machine, "context": target.name,
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
				return "", fmt.Errorf("Could not reach CYFR to learn whether the command line "+
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
// bound of its own since the command's context may already have ended,
// and answers the home's failure to hear it, which callers say: whatever
// an approval signed in may then still be active, for the person to
// revoke under Devices.
func withdraw(client *mcp.Client, token string) error {
	ctx, cancel := context.WithTimeout(context.Background(), cliWithdrawTimeout)
	defer cancel()
	_, err := client.CallTool(ctx, ops.Session, ops.SessionCliCancelArgs{SessionToken: token})
	return err
}

// unwithdrawn says, on stderr, that the home did not hear a withdrawal.
func unwithdrawn(err error) {
	fmt.Fprintf(os.Stderr, "CYFR could not be told the command line stopped waiting (%v). "+
		"If the link is approved before it expires, revoke the command line under Devices in Prism.\n", err)
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

// storedContext is the stored context a command signs in to or out of,
// as the one read of the configuration that validated it found it: its
// name, its address and the credential it held. The command's client is
// built from this read (clientAt), never from another, so a context set
// or changed meanwhile sends no credential to another home.
type storedContext struct {
	name    string
	address string
	token   string
}

// sessionContext is the stored context cyfr login saves its session under
// and cyfr logout ends the session of: --context, or the current one. A
// context that does not exist, or a --url that is not its address, is
// refused before anything is asked of a home or changed here: a session
// saved under another home's context would be sent there with every later
// command, and a logout sent to another home hands it this one's session.
func sessionContext(verb string) (storedContext, error) {
	cfg, err := config.Load()
	if err != nil {
		return storedContext{}, fmt.Errorf("Could not read the command line's config: %w", err)
	}
	name := contextName(cfg)
	stored := cfg.Contexts[name]
	if stored == nil {
		return storedContext{}, fmt.Errorf("No context named %q to %s: add it with "+
			"cyfr context add %s <url>.", name, verb, name)
	}
	if flagURL != "" && !sameAddress(flagURL, stored.URL) {
		return storedContext{}, fmt.Errorf("--url %s is not the address of the context %q (%s), "+
			"and that context's session belongs to its own CYFR. Add a context for it "+
			"(cyfr context add <name> %s), then use --context <name>.",
			flagURL, name, stored.URL, flagURL)
	}
	return storedContext{name: name, address: stored.URL, token: stored.Token}, nil
}

// sameAddress is whether two addresses name one home, a trailing slash
// aside. A scheme and a host name are case-insensitive (RFC 3986 §3.1 and
// §3.2.2), so their case is folded; a path and a query are compared byte
// for byte, since their case is the server's to give a meaning to, and a
// path can tell two homes behind one host apart.
func sameAddress(a, b string) bool {
	ua, errA := url.Parse(strings.TrimRight(a, "/"))
	ub, errB := url.Parse(strings.TrimRight(b, "/"))
	if errA != nil || errB != nil {
		return a == b
	}
	return strings.EqualFold(ua.Scheme, ub.Scheme) && strings.EqualFold(ua.Host, ub.Host) &&
		ua.User.String() == ub.User.String() && ua.EscapedPath() == ub.EscapedPath() &&
		ua.RawQuery == ub.RawQuery && ua.Fragment == ub.Fragment
}

// errContextMoved is the context a sign-in began under naming another
// address by the time its session would be saved.
var errContextMoved = errors.New("the context was changed to another address while this command line signed in")

// saveSession stores token as the credential of the context target names,
// only while that context still names the address the sign-in began at:
// one changed meanwhile (cyfr context add with the same name) is
// errContextMoved and saves nothing, since the session would then be sent
// to the other home with every later command.
func saveSession(target storedContext, token string) error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}
	stored := cfg.Contexts[target.name]
	if stored == nil {
		return fmt.Errorf("the context %q is gone", target.name)
	}
	if !sameAddress(stored.URL, target.address) {
		return fmt.Errorf("%w (%q now names %s, not %s)", errContextMoved, target.name, stored.URL, target.address)
	}
	stored.Token = token
	return cfg.Save()
}
