// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
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
	flagLoginName     string
)

func init() {
	loginCmd.Flags().StringVar(&flagLoginProvider, "provider", "",
		"Sign in with an OAuth provider's device flow instead of approving in Prism ("+
			strings.Join(ops.DeviceFlowProviders, " or ")+")")
	loginCmd.Flags().BoolVar(&flagLoginSetup, "setup", false,
		"Sign in as this CYFR's first person with CYFR_SETUP_TOKEN from .env in this directory, setting them up the first time (a headless CYFR)")
	loginCmd.Flags().StringVar(&flagLoginName, "name", "",
		"With --setup: the first person's name, theirs for life (asked for on a terminal when not given)")

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

A headless CYFR (CYFR_HEADLESS=on) serves no setup page, so --setup makes
its first person, who administers it. Run in the directory cyfr init set
up, it reads CYFR_SETUP_TOKEN from .env there and the person's name from
--name, or asks for it on a terminal: the name is theirs for life. It takes
the name at cyfr.run and prints the person's recovery code, and once they
press Enter to say they saved it, signs the command line in as that person.
When cyfr.run does not answer, nothing is saved: run it again to finish.
Run again, it signs the same person in again, with the same recovery code
until it is saved, until they have a passkey, a device they connected or a
sign-in method they linked; from then on the token opens nothing, and the
command line signs in with cyfr login.

The session is saved under the context the command used: --context, or the
current one. A --url that is not that context's address saves nothing; add a
context for it first (cyfr context add <name> <url>). A context changed to
another address while the command waits keeps nothing: the sign-in is
withdrawn.`,
	Example: `  cyfr login
  cyfr login --context work
  cyfr login --provider google
  cyfr login --setup --name mira`,
	RunE: func(cmd *cobra.Command, args []string) error {
		if flagLoginSetup && cmd.Flags().Changed("provider") {
			return errors.New("--setup signs in with this CYFR's setup token and --provider with a provider: use one of them.")
		}
		if !flagLoginSetup && cmd.Flags().Changed("name") {
			return errors.New("--name names the first person --setup makes: use it with --setup.")
		}
		target, err := sessionContext("save the session under")
		if err != nil {
			return err
		}

		if cmd.Flags().Changed("provider") && !slices.Contains(ops.DeviceFlowProviders, flagLoginProvider) {
			return fmt.Errorf("Unsupported provider %q — use '%s'.", flagLoginProvider,
				strings.Join(ops.DeviceFlowProviders, "' or '"))
		}

		var setupToken, name string
		if flagLoginSetup {
			if setupToken, err = setupTokenHere(); err != nil {
				return err
			}
			if name, err = setupName(cmd.Context(), setupOutput(), cmd.Flags().Changed("name")); err != nil {
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
			return loginWithSetup(cmd.Context(), client, target, setupToken, machineName(), name)
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

// loginWithSetup makes this CYFR's first person with its setup token
// (session.setup), the name given and a recovery secret drawn here, takes
// the name at cyfr.run (registry.register), prints the recovery code and,
// once the person presses Enter to say they saved it
// (person.recovery_code_saved), keeps the session as the device flow keeps
// one. Each later call signs the same person in again while they hold no
// passkey, no device they connected and no sign-in method they linked, and
// CYFR answers the same attempt and code until the code is saved, and no
// code after. Every way out before the session is kept ends the session
// CYFR answered (endSession), so no credential outlives a run that saved
// none.
func loginWithSetup(ctx context.Context, client *mcp.Client, target storedContext, token, machine, name string) error {
	answer, err := client.CallTool(ctx, ops.Session, ops.SessionSetupArgs{SetupToken: &token, Machine: machine,
		Name: name, RecoverySecret: drawRecoverySecret(), RequestId: drawRequestID()})
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
	client.SessionID = sessionID

	named, err := finishSetup(ctx, client, answer, name)
	if err != nil {
		endSession(ctx, client)
		return err
	}
	if err := keepSession(ctx, client, target, sessionID); err != nil {
		return err
	}

	if flagJSON {
		readmitted, _ := answer["readmitted"].(bool)
		recovery, _ := answer["recovery"].(map[string]any)
		output.JSON(map[string]any{"status": "signed_in", "context": target.name, "user_id": answer["user_id"],
			"readmitted": readmitted, "name": named, "identifier": recovery["identifier"]})
		return nil
	}
	fmt.Printf("Signed in as @%s. Add another recovery code in Settings.\n", named)
	return nil
}

// finishSetup takes the person's name at cyfr.run and, while session.setup
// answered a recovery code, prints it and records it saved once the person
// presses Enter. It answers the name the person holds.
func finishSetup(ctx context.Context, client *mcp.Client, answer map[string]any, wanted string) (string, error) {
	recovery, _ := answer["recovery"].(map[string]any)
	attemptID, _ := recovery["attempt_id"].(string)
	held, _ := recovery["name"].(string)
	code, _ := recovery["code"].(string)
	if attemptID == "" || held == "" {
		return "", errors.New("CYFR answered no name and recovery code, so nothing was saved. Run cyfr login --setup again.")
	}

	out := setupOutput()
	named, err := registerName(ctx, client, out, wanted, held)
	if err != nil || code == "" {
		return named, err
	}

	fmt.Fprintf(out, "Your name is @%s.\n", named)
	fmt.Fprintln(out, "Your recovery code:")
	fmt.Fprintln(out, code)
	fmt.Fprintln(out, "If this CYFR is ever lost, this is the one thing that brings you back. "+
		"Save it in your password manager. Press Enter once you saved it.")
	if err := awaitEnter(ctx); err != nil {
		return "", err
	}
	if _, err := client.CallTool(ctx, ops.Person, ops.PersonRecoveryCodeSavedArgs{AttemptId: attemptID}); err != nil {
		return "", setupCallFailure(err)
	}
	return named, nil
}

// registerName takes the name at cyfr.run (registry.register), first the
// one the attempt holds, and answers the name taken. A name cyfr.run holds
// for someone else or keeps for itself is followed by the name this run
// was given, when the attempt held another (a readmission keeps the name
// of the run that made the person), and then by the one the person types
// on a terminal; off a terminal the refusal ends the run. A silent cyfr.run
// ends it as a run to repeat.
func registerName(ctx context.Context, client *mcp.Client, out io.Writer, wanted, held string) (string, error) {
	args, tried := ops.RegistryRegisterArgs{}, held
	for {
		answer, err := client.CallTool(ctx, ops.Registry, args)
		switch {
		case err == nil:
			if named, _ := answer["name"].(string); named != "" {
				return named, nil
			}
			return tried, nil
		case refusedAs(err, "directory_unavailable", "registry_unavailable"):
			return "", errors.New("cyfr.run did not answer. Run cyfr login --setup again to finish.")
		case !refusedAs(err, "name_taken", "name_reserved"):
			return "", setupCallFailure(err)
		case wanted != tried:
			// The attempt held another run's name: this run's is next.
		case !confirmationTerminal():
			return "", fmt.Errorf("%w\nRun cyfr login --setup --name NAME with another name to finish.", err)
		default:
			fmt.Fprintln(out, err)
			var asked error
			switch wanted, asked = askName(ctx, out); {
			case errors.Is(asked, io.EOF):
				return "", fmt.Errorf("%w\nRun cyfr login --setup --name NAME with another name to finish.", err)
			case asked != nil:
				return "", interrupted("Stopped before your name was taken. Run cyfr login --setup again to finish.")
			}
		}
		args, tried = ops.RegistryRegisterArgs{Name: ops.Value(wanted)}, wanted
	}
}

// registerRefusals are the sentences Prima.Refusal answers the refusals of
// registry.register the command line acts on, which reach it as a tool
// error's text alone. login_test.go holds them to
// apps/prima/lib/prima/refusal.ex.
var registerRefusals = map[string]string{
	"name_taken":            "Someone holds that name. Choose another.",
	"name_reserved":         "cyfr.run keeps that name for itself. Choose another.",
	"directory_unavailable": "cyfr.run did not answer. Try again.",
	"registry_unavailable":  "The registry could not be reached just now; try again shortly.",
}

// refusedAs is whether err is CYFR's refusal for one of reasons.
func refusedAs(err error, reasons ...string) bool {
	for _, reason := range reasons {
		if err.Error() == registerRefusals[reason] {
			return true
		}
	}
	return false
}

// setupCallFailure is a call after session.setup that failed: an
// interruption, CYFR not answering, or CYFR's refusal as it answered it.
func setupCallFailure(err error) error {
	switch {
	case errors.Is(err, context.Canceled):
		return interrupted("Stopped before CYFR answered. Run cyfr login --setup again to finish.")
	case errors.As(err, new(*url.Error)):
		return fmt.Errorf("Failed to set up: %w", err)
	default:
		return err
	}
}

// endSession ends the session session.setup answered, for a run that keeps
// none. It is asked after an interruption too, for a few seconds, and its
// failure leaves the run's own report standing: the session also expires.
func endSession(ctx context.Context, client *mcp.Client) {
	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
	defer cancel()
	_, _ = client.CallTool(ctx, ops.Session, ops.SessionLogoutArgs{})
}

// setupOutput is where --setup speaks to the person: standard output, or
// standard error under --json, whose standard output is the answer alone.
func setupOutput() io.Writer {
	if flagJSON {
		return os.Stderr
	}
	return os.Stdout
}

// setupName is the name --setup gives the first person: --name, else the
// one they type on a terminal. With neither it is refused before anything
// reaches CYFR.
func setupName(ctx context.Context, out io.Writer, given bool) (string, error) {
	if name := typedName(flagLoginName); given && name != "" {
		return name, nil
	}
	errNoName := errors.New("Give your name with --name. It is yours for life.")
	if !confirmationTerminal() {
		return "", errNoName
	}
	switch name, err := askName(ctx, out); {
	case errors.Is(err, io.EOF):
		return "", errNoName
	case err != nil:
		return "", interruption{errQuestionInterrupted}
	default:
		return name, nil
	}
}

// askName asks for a name on the terminal until one is typed, answering
// io.EOF when the input ends first and the context's error when the person
// leaves the question.
func askName(ctx context.Context, out io.Writer) (string, error) {
	for {
		fmt.Fprint(out, "Your name: @")
		select {
		case <-ctx.Done():
			fmt.Fprintln(out)
			return "", ctx.Err()
		case line, open := <-confirmationInput():
			if !open {
				fmt.Fprintln(out)
				return "", io.EOF
			}
			if name := typedName(line); name != "" {
				return name, nil
			}
		}
	}
}

// typedName is a name as typed, without the @ that is written before it
// and the spaces around it; CYFR checks its spelling.
func typedName(typed string) string {
	return strings.TrimPrefix(strings.TrimSpace(typed), "@")
}

// awaitEnter waits for the person to press Enter, read from standard input
// whether or not it is a terminal, so a script that saved the code answers
// it too. Input that ends first saves nothing.
func awaitEnter(ctx context.Context) error {
	select {
	case <-ctx.Done():
		return interrupted("Stopped before you saved your recovery code. Run cyfr login --setup again to finish.")
	case _, open := <-confirmationInput():
		if !open {
			return errors.New("The input ended before you saved your recovery code, so nothing was saved. " +
				"Run cyfr login --setup again to finish.")
		}
		return nil
	}
}

// drawRecoverySecret is a new recovery code's secret: 32 bytes from
// crypto/rand as unpadded base64url, the browser's form. crypto/rand.Read
// fails only by ending the process.
func drawRecoverySecret() string {
	secret := make([]byte, 32)
	_, _ = rand.Read(secret)
	return base64.RawURLEncoding.EncodeToString(secret)
}

// drawRequestID is the request id of the attempt the admission opens: req_
// and 32 hexadecimal digits, the browser's form.
func drawRequestID() string {
	id := make([]byte, 16)
	_, _ = rand.Read(id)
	return "req_" + hex.EncodeToString(id)
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
