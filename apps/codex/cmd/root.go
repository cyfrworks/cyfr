// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/signal"
	"strings"
	"syscall"
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
)

var rootCmd = &cobra.Command{
	Use:   "cyfr",
	Short: "CYFR CLI — sandboxed component runtime for AI agents",
	Long: `cyfr is the command-line interface for CYFR — a sandboxed runtime
where AI agents execute WASM tools and serve tincture frontends via MCP.
Use cyfr to manage components, vault entries, consents, and executions
from the terminal or scripts.

Exit status: 0 on success; 1 on a failure; 3 when cyfr up, update,
restore or access started CYFR on this machine only, because
the tailnet machine is not ready to serve it (not the one .env names, not
joined, or HTTPS off; the message says what to do);
130 when interrupted at a prompt.`,
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

// The exit statuses of a cyfr process, apart from the watchdog's
// (`cyfr internal docker-run`), whose status is its docker call's.
const (
	exitFailure        = 1
	exitStartedLocally = 3
	exitInterrupted    = 130
)

// ExitStatus is the exit status a command's failure ends the process with:
// 130 for the person's own Ctrl-C at a prompt, the status the shell
// reserves for it (128+SIGINT), which Execute prints nothing for; 3 for a
// start that left the home running on this machine only (its tailnet
// machine is not ready to serve it), which must read neither as a success
// nor as a start that failed; the status of the updated cyfr a `cyfr
// update` ran as a child to finish (handedOver), which printed its own
// outcome; and 1 for every other failure.
func ExitStatus(err error) int {
	if errors.Is(err, prompt.ErrAborted) {
		return exitInterrupted
	}
	if child := (handedOver{}); errors.As(err, &child) {
		return child.status
	}
	if local := (startedLocally{}); errors.As(err, &local) {
		return exitStartedLocally
	}
	return exitFailure
}

// interruption is a command the person interrupted at a question (Ctrl-C,
// or the terminal closing), which Execute prints as its sentence alone and
// which exits 130 (prompt.ErrAborted): the sentence says what was left as
// it was.
type interruption struct{ err error }

func (i interruption) Error() string   { return i.err.Error() }
func (i interruption) Unwrap() []error { return []error{i.err, prompt.ErrAborted} }

// errQuestionInterrupted is a question interrupted before its command
// wrote or started anything.
var errQuestionInterrupted = errors.New("Interrupted; nothing was written.")

// Main is the cyfr process: Ctrl-C, SIGTERM and SIGHUP (the terminal
// closed) cancel the context every command runs under, so a command
// unwinds through its own cleanup, a waiting tailnet join cancelled and the
// lock released, rather than die with them; it answers the status the
// process exits with (Run).
func Main() int {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM, syscall.SIGHUP)
	defer stop()
	return Run(ctx)
}

// Run is the command line executed under ctx, answered as the status the
// process exits with, 0 or ExitStatus of the failure Execute printed.
func Run(ctx context.Context) int {
	if err := Execute(ctx); err != nil {
		return ExitStatus(err)
	}
	return 0
}

// Execute runs the root command under the process context, so every
// request a command makes is cancellable by the signals Main names. It
// prints the failure (cobra's own printing is silenced) — except a prompt
// abort, which the user caused and needs no telling about beyond an
// interrupted question's sentence of what it left, and the status
// of an updated cyfr that printed its own — and returns it for main to map
// to an exit code.
func Execute(ctx context.Context) error {
	err := rootCmd.ExecuteContext(ctx)
	if i := (interruption{}); errors.As(err, &i) {
		fmt.Fprintln(os.Stderr, i)
	}
	if err != nil && !errors.Is(err, prompt.ErrAborted) && !errors.As(err, new(handedOver)) {
		fmt.Fprintln(os.Stderr, "Error:", err)
		// The one line SilenceErrors swallows beyond the error itself:
		// cobra's help pointer after an unrecognized command.
		if strings.HasPrefix(err.Error(), "unknown command ") {
			fmt.Fprintf(os.Stderr, "Run '%s --help' for usage.\n", rootCmd.CommandPath())
		}
	}
	return err
}

// newClient creates an MCP client for the selected context, with the
// invocation's credential (clientAt).
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

	return clientAt(serverURL(cfg))
}

// clientAt is the client for the home at address, holding the credential
// --token names, else CYFR_TOKEN (an API key, the unattended path), else
// the session of the shell cyfr login holds for that address
// (shellSession). Nothing stored sends a credential: the command line
// proves the person with its device, whose session lives in memory.
func clientAt(address string) *mcp.Client {
	client := mcp.NewClient(address)
	// A change answered confirmation_required waits here and repeats, for
	// every command alike.
	client.Confirm = (&confirmationWait{
		out:         os.Stderr,
		interactive: confirmationTerminal,
		lines:       confirmationInput,
		now:         time.Now,
		address:     address,
		device:      confirmOnDevice,
	}).wait

	switch {
	case flagToken != "":
		client.SessionID = flagToken
	case os.Getenv("CYFR_TOKEN") != "":
		client.SessionID = os.Getenv("CYFR_TOKEN")
	default:
		client.SessionID, _ = shellSession(address)
	}

	return client
}

// contextName is the stored context a command uses: --context, or the
// current one.
func contextName(cfg *config.Config) string {
	if flagContext != "" {
		return flagContext
	}
	return cfg.CurrentContext
}

// serverURL is the home's address a command talks to: --url, else the
// --context's address, else the current context's.
func serverURL(cfg *config.Config) string {
	if flagURL != "" {
		return flagURL
	}
	if stored := cfg.Contexts[contextName(cfg)]; stored != nil {
		return stored.URL
	}
	return cfg.CurrentURL()
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
		return errors.New("Not signed in. Run 'cyfr login': it unlocks this command line in a shell of its own. Unattended work uses an API key (--token or CYFR_TOKEN).")
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

// Render typed consent errors using the payload in error.data.
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

	case "confirmation_required":
		// Never a success: nothing was changed. The payload's id is this
		// request's secret: the CLI repeats the change under it and never
		// shows it. The person confirms the record on a device of theirs,
		// which names it
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
		return fmt.Sprintf("Confirmation required: %s needs a fresh confirmation; nothing was changed.\n  Confirm %s on a device of yours%s (a passkey in Prism, a CYFR screen, or a command line paired by cyfr login), where this key or client is named as the one asking.", operation, record, expiry)
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

// confirmationWait is how a command meets a change answered
// confirmation_required (mcp.Client.Confirm). On a terminal it prints the
// sentence, which names the record by its ref, and waits: each Enter repeats
// the call once, a repeat answered with the same id waits again, and the
// wait ends at the record's expiry. Where this command line holds a
// paired device for the home (device), it first offers to confirm the
// change here: the home's preview is drawn, then the PIN or passphrase
// typed after it confirms it (confirmOnDevice) and the call is repeated,
// or Enter alone repeats it once confirmed elsewhere. Off a terminal, or
// past the expiry, it ends at once with the signal itself, which the
// command prints before exiting 1: nothing was changed, and the id is
// dropped with the process. Ctrl-C leaves it (exit 130).
type confirmationWait struct {
	out         io.Writer
	interactive func() bool
	lines       func() <-chan []byte
	now         func() time.Time
	address     string
	device      func(address string) deviceConfirmer
}

func (w *confirmationWait) wait(ctx context.Context, pending *mcp.ConsentError, again bool) error {
	expiresAt, expires := confirmationExpiry(pending.Payload)
	if !w.interactive() || (expires && !w.now().Before(expiresAt)) {
		return pending
	}

	id, _ := pending.Payload["id"].(string)
	if again {
		fmt.Fprintf(w.out, "Not confirmed yet: %s is still waiting.\n", confirmation.Ref(id))
	} else {
		fmt.Fprintln(w.out, formatConsentError(pending.Tag, pending.Payload))
	}
	var expired <-chan time.Time
	if expires {
		timer := time.NewTimer(expiresAt.Sub(w.now()))
		defer timer.Stop()
		expired = timer.C
	}

	if w.device != nil && id != "" {
		if here := w.device(w.address); here != nil {
			// The record's expiry ends the offer as it ends the wait.
			dctx, cancel := context.WithCancel(ctx)
			lapsed := make(chan bool, 1)
			go func() {
				select {
				case <-expired:
					lapsed <- true
					cancel()
				case <-dctx.Done():
					lapsed <- false
				}
			}()
			outcome, err := here(dctx, confirmation.Ref(id), &console{out: w.out, lines: w.lines, quiet: echoOff})
			cancel()
			switch {
			case <-lapsed:
				return pending
			case ctx.Err() != nil:
				return prompt.ErrAborted
			case errors.Is(err, errInputEnded):
				return pending
			case outcome == failedHere:
				fmt.Fprintln(w.out, err)
				return nil
			case outcome == notHere:
				if err != nil && err.Error() != "" {
					fmt.Fprintln(w.out, err)
				}
			default:
				return nil
			}
		}
	}
	fmt.Fprintln(w.out, "  Press Enter once confirmed, Ctrl-C to leave it.")

	select {
	case <-ctx.Done():
		return prompt.ErrAborted
	case <-expired:
		return pending
	case line, open := <-w.lines():
		if !open {
			return pending
		}
		clear(line)
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
