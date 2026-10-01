// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/cyfr/codex/internal/config"
	"github.com/cyfr/codex/internal/confirmation"
	"github.com/cyfr/codex/internal/mcp"
	"github.com/cyfr/codex/internal/output"
	"github.com/cyfr/codex/internal/prompt"
	"github.com/cyfr/codex/internal/version"
	"github.com/spf13/cobra"
)

var (
	flagJSON          bool
	flagURL           string
	flagContext       string
	flagNoInteractive bool
	flagToken         string
	flagVersions      bool

	// activeClient tracks the MCP client for session cleanup on exit.
	activeClient *mcp.Client
)

var rootCmd = &cobra.Command{
	Use:   "cyfr",
	Short: "CYFR CLI — sandboxed component runtime for AI agents",
	Long: `cyfr is the command-line interface for CYFR — a sandboxed runtime
where AI agents execute WASM tools and serve tincture frontends via MCP.
Use cyfr to manage components, vault entries, consents, and executions
from the terminal or scripts.`,
	PersistentPostRun: func(cmd *cobra.Command, args []string) {
		// This transport has no server-side session to terminate — the
		// credential authenticates each request on its own (client.Close
		// only clears client-side state). Kept so a future transport with
		// a teardown has its hook already wired.
		if activeClient != nil {
			_ = activeClient.Close()
		}
	},
	// Commands report failures by returning an error (Execute prints it as
	// "Error: …" on stderr); a failure is not a usage mistake, so no help
	// text dump rides along. Errors are printed by Execute rather than by
	// cobra so a prompt abort (prompt.ErrAborted) can exit 130 silently.
	SilenceUsage:  true,
	SilenceErrors: true,
}

func init() {
	rootCmd.PersistentFlags().BoolVar(&flagJSON, "json", false, "Output as JSON")
	rootCmd.PersistentFlags().StringVar(&flagURL, "url", "", "Override server URL")
	rootCmd.PersistentFlags().StringVar(&flagContext, "context", "", "Use specific context")
	rootCmd.PersistentFlags().BoolVar(&flagNoInteractive, "no-interactive", false, "Disable interactive prompts")
	rootCmd.PersistentFlags().StringVar(&flagToken, "token", "",
		"Bearer credential for this invocation (a cyfr_ API key or session token); "+
			"overrides the stored one. CYFR_TOKEN works too — the non-interactive path for CI.")

	rootCmd.AddGroup(
		&cobra.Group{ID: "server", Title: "Server:"},
		&cobra.Group{ID: "identity", Title: "Identity:"},
		&cobra.Group{ID: "component", Title: "Components:"},
		&cobra.Group{ID: "security", Title: "Security:"},
		&cobra.Group{ID: "admin", Title: "Administration:"},
	)

	rootCmd.Version = version.Version
	rootCmd.SetUsageFunc(customUsage)
}

// Execute runs the root command under the process context, so every request
// a command makes is cancellable by Ctrl-C / SIGTERM. It prints the failure
// (cobra's own printing is silenced) — except a prompt abort, which the user
// caused and needs no telling about — and returns it for main to map to an
// exit code.
func Execute(ctx context.Context) error {
	err := rootCmd.ExecuteContext(ctx)
	if err != nil && !errors.Is(err, prompt.ErrAborted) {
		fmt.Fprintln(os.Stderr, "Error:", err)
		// The one line SilenceErrors swallows beyond the error itself:
		// cobra's help pointer after an unrecognized command.
		if strings.HasPrefix(err.Error(), "unknown command ") {
			fmt.Fprintf(os.Stderr, "Run '%s --help' for usage.\n", rootCmd.CommandPath())
		}
	}
	return err
}

// newClient creates an MCP client from config.
// If no cached session exists, it tries to initialize with the server
// to auto-adopt a session created via browser login (Prism).
func newClient() *mcp.Client {
	cfg, err := config.Load()
	if err != nil {
		cfg = &config.Config{
			CurrentContext: "local",
			Contexts: map[string]*config.Context{
				"local": {URL: "http://127.0.0.1:4000"},
			},
		}
	}

	// Override context if flag is set
	if flagContext != "" {
		cfg.CurrentContext = flagContext
	}

	url := cfg.CurrentURL()
	if flagURL != "" {
		url = flagURL
	}

	client := mcp.NewClient(url)
	activeClient = client

	// A change answered confirmation_required waits here and repeats, for
	// every command alike.
	client.Confirm = (&confirmationWait{
		out:         os.Stderr,
		interactive: confirmationTerminal,
		lines:       confirmationInput,
		now:         time.Now,
	}).wait

	// The credential authenticates every request; there is nothing to
	// establish up front. Precedence: --token, then CYFR_TOKEN (the CI
	// path — no config file to hand-write), then the stored context.
	// Without one, commands that need auth will say so.
	switch {
	case flagToken != "":
		client.SessionID = flagToken
	case os.Getenv("CYFR_TOKEN") != "":
		client.SessionID = os.Getenv("CYFR_TOKEN")
	default:
		if ctx := cfg.Current(); ctx != nil {
			client.SessionID = ctx.Credential()
		}
	}

	return client
}

// handleToolError maps well-known error sentinels to a helpful message,
// otherwise falls back to a contextual or generic error. Commands return the
// result so Execute prints it and main exits non-zero.
// Pass an optional prefix string (e.g. "Register failed") for the fallback.
func handleToolError(err error, prefix ...string) error {
	// Leaving a wait for a fresh confirmation is the person's own Ctrl-C:
	// Execute prints nothing for it and main exits 130.
	if errors.Is(err, prompt.ErrAborted) {
		return prompt.ErrAborted
	}
	// Capitalized, punctuated messages are deliberate here (staticcheck
	// ST1005 would object): these errors ARE the CLI's user-facing output —
	// Execute prints them verbatim as the command's final line.
	if errors.Is(err, mcp.ErrAuthRequired) {
		return errors.New("Not logged in. Run 'cyfr login' to authenticate.")
	}
	if msg, ok := explainConsentError(err); ok {
		return errors.New(msg)
	}
	if len(prefix) > 0 && prefix[0] != "" {
		return fmt.Errorf("%s: %w", prefix[0], err)
	}
	return fmt.Errorf("Failed: %w", err)
}

// renderResult prints a tool result in the format the invocation selected:
// JSON under --json, the key/value layout otherwise. It returns nil so a
// command's final render can be its return statement.
func renderResult(result map[string]any) error {
	if flagJSON {
		output.JSON(result)
	} else {
		output.KeyValue(result)
	}
	return nil
}

// Render typed consent errors (codes -33501..-33505) using the
// payload in error.data.
func explainConsentError(err error) (string, bool) {
	var ce *mcp.ConsentError
	if !errors.As(err, &ce) {
		return "", false
	}
	return formatConsentError(ce.Tag, ce.Payload), true
}

func formatConsentError(tag string, payload map[string]any) string {
	switch tag {
	case "setup_required":
		ref, _ := payload["node_ref"].(string)
		need, _ := payload["need"].(string)
		if need != "" {
			return fmt.Sprintf("Setup required: %s needs a vault entry for %q.\n  Run: cyfr profile grant %s", ref, need, ref)
		}
		return fmt.Sprintf("Setup required: %s is not ready.\n  Run: cyfr profile grant %s", ref, ref)

	case "consent_required":
		rev, _ := payload["current_revision"].(float64)
		return fmt.Sprintf("This app's permissions changed since you approved them (consent rev %.0f).\n  Run: cyfr profile grant <ref> to review and approve.", rev)

	case "consent_conflict":
		cause, _ := payload["cause"].(string)
		actual, _ := payload["actual_revision"].(float64)
		return fmt.Sprintf("Consent changed while you were deciding (%s; current revision %.0f).\n  Re-run the grant to decide against what is true now.", cause, actual)

	case "restart_required":
		rev, _ := payload["new_revision"].(float64)
		return fmt.Sprintf("Approved (consent rev %.0f) — re-run the command to continue.\n  The run that was in flight was stopped rather than re-bound mid-execution.", rev)

	case "confirmation_required":
		// Never a success: nothing was changed. The payload's id is this
		// request's secret: the CLI repeats the change under it and never
		// shows it. The person confirms the record in Prism, which names it
		// by its ref and names this key or client as the one asking.
		operation, _ := payload["operation"].(string)
		if operation == "" {
			operation = "this change"
		}
		record := "it"
		if id, _ := payload["id"].(string); id != "" {
			record = confirmation.Ref(id)
		}
		expiry := ""
		if expiresAt, _ := payload["expires_at"].(string); expiresAt != "" {
			expiry = fmt.Sprintf(" before %s", expiresAt)
		}
		return fmt.Sprintf("Confirmation required: %s needs a fresh confirmation; nothing was changed.\n  Confirm %s in Prism%s, where this key or client is named as the one asking.", operation, record, expiry)
	}

	return ""
}

// The terminal a wait for a fresh confirmation talks to: whether there is
// one to wait on (--no-interactive and CYFR_NO_INTERACTIVE say there is
// not), and the lines read from it. Tests stand in for both.
var (
	confirmationTerminal = func() bool { return prompt.IsInteractive(flagNoInteractive) }
	confirmationInput    = stdinLines
)

// stdinLines is the person's Enter presses on standard input, read by one
// reader for the whole process: a read cannot be cancelled, so a second
// reader would race the first for the next line. The channel closes at end
// of input.
var stdinLines = sync.OnceValue(func() <-chan string {
	lines := make(chan string)
	go func() {
		defer close(lines)
		scanner := bufio.NewScanner(os.Stdin)
		for scanner.Scan() {
			lines <- scanner.Text()
		}
	}()
	return lines
})

// confirmationWait is how a command meets a change answered
// confirmation_required (mcp.Client.Confirm). On a terminal it prints the
// sentence, which names the record by its ref, and waits: each Enter repeats
// the call once, a repeat answered with the same id waits again, and the
// wait ends at the record's expiry. Off a terminal, or past the expiry, it
// ends at once with the signal itself, which the command prints before
// exiting 1: nothing was changed, and the id is dropped with the process.
// Ctrl-C leaves it (exit 130).
type confirmationWait struct {
	out         io.Writer
	interactive func() bool
	lines       func() <-chan string
	now         func() time.Time
}

func (w *confirmationWait) wait(ctx context.Context, pending *mcp.ConsentError, again bool) error {
	expiresAt, expires := confirmationExpiry(pending.Payload)
	if !w.interactive() || (expires && !w.now().Before(expiresAt)) {
		return pending
	}

	if again {
		id, _ := pending.Payload["id"].(string)
		fmt.Fprintf(w.out, "Not confirmed yet: %s is still waiting in Prism.\n", confirmation.Ref(id))
	} else {
		fmt.Fprintln(w.out, formatConsentError(pending.Tag, pending.Payload))
	}
	fmt.Fprintln(w.out, "  Press Enter once confirmed, Ctrl-C to leave it.")

	var expired <-chan time.Time
	if expires {
		timer := time.NewTimer(expiresAt.Sub(w.now()))
		defer timer.Stop()
		expired = timer.C
	}

	select {
	case <-ctx.Done():
		return prompt.ErrAborted
	case <-expired:
		return pending
	case _, open := <-w.lines():
		if !open {
			return pending
		}
		return nil
	}
}

// confirmationExpiry is when the pending confirmation expires, if its
// payload says.
func confirmationExpiry(payload map[string]any) (time.Time, bool) {
	raw, _ := payload["expires_at"].(string)
	expiresAt, err := time.Parse(time.RFC3339, raw)
	if err != nil {
		return time.Time{}, false
	}
	return expiresAt, true
}
