// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"regexp"
	"strings"
	"time"

	"github.com/cyfr/codex/internal/prompt"
	"github.com/cyfr/codex/internal/reach"
	"github.com/spf13/cobra"
)

// stackEngine is the reach engine (reach.Engine) as the commands that
// start, stop, change or read the stack use it. It owns the project's
// lock, its recovery, every docker call made under the lock and the reach
// keys of .env.
type stackEngine interface {
	Lock(holder string) (func(), error)
	Resume(ctx context.Context) ([]reach.Receipt, error)
	Docker() reach.Docker
	ComposeArgs(ctx context.Context, h reach.Head, args ...string) ([]string, error)
	Head() (reach.Head, error)
	CheckStack(ctx context.Context) error
	Status(ctx context.Context) (reach.Status, error)
	Preview(ctx context.Context, t reach.Target, joinID string) (reach.Preview, error)
	Switch(ctx context.Context, r reach.SwitchRequest) (reach.Receipt, error)
	Join(ctx context.Context, r reach.JoinRequest) (reach.Receipt, error)
	CancelWaitingJoin(ctx context.Context) error
	ForgetJoin() error
	Start(ctx context.Context, cause string) (reach.Receipt, error)
	Stop(ctx context.Context, cause string, all bool) (reach.Receipt, error)
}

// openEngine opens the engine of the project at dir, refusing a .env that
// sets a COMPOSE_* key before anything reads it. A variable so a test
// stands in a fake engine.
var openEngine = func(dir string) (stackEngine, error) {
	e, err := reach.Open(dir, nil)
	if err != nil {
		return nil, err
	}
	return e, nil
}

// The refusal a receipt answers with and the lock's refusal while another
// holder has it, as the engine renders them; variables so a test's fake
// engine answers its own.
var (
	receiptRefusal = reach.Receipt.Refusal
	busyRefusal    = (*reach.ErrBusy).Refusal
)

// refusalError is a refusal as a command's failure: Execute prints its
// sentence, and the command exits non-zero.
type refusalError struct{ r *reach.Refusal }

func (e refusalError) Error() string { return e.r.Message() }
func (e refusalError) Unwrap() error { return e.r }

// engineFailure is err as a command reports it: a refusal, the lock's
// included, by its sentence, anything else as it is.
func engineFailure(err error) error {
	var busy *reach.ErrBusy
	if errors.As(err, &busy) {
		if r := busyRefusal(busy); r != nil {
			return refusalError{r}
		}
	}
	var r *reach.Refusal
	if errors.As(err, &r) {
		return refusalError{r}
	}
	return err
}

// outcomeStartedLocal is the outcome of a start that started the home on
// this machine alone: the machine's tailnet node is not the one .env
// names, so Serve stays closed, and the receipt answers
// tailnet_node_mismatch.
const outcomeStartedLocal = "started_local"

// startedLocally is a start that left the home running on this machine
// alone (outcomeStartedLocal). It is no success: its sentence says the home
// answers on this machine only and to run `cyfr reach tailnet`, and the
// process exits 3 (ExitStatus), apart from a start that failed.
type startedLocally struct{ refusalError }

// receiptFailure is the failure a receipt answers, nil for a plain
// success; a start that left the home on this machine alone answers
// startedLocally.
func receiptFailure(rec reach.Receipt) error {
	r := receiptRefusal(rec)
	if rec.Outcome == outcomeStartedLocal {
		if r == nil {
			r = reach.Refuse("tailnet_node_mismatch", rec.Payload)
		}
		return startedLocally{refusalError{r}}
	}
	if r != nil {
		return refusalError{r}
	}
	return nil
}

// openLocked opens the project's engine in the working directory, takes
// its lock for command and runs recovery, printing each receipt recovery
// wrote. It answers the engine, the function that releases the lock, and
// those receipts.
func openLocked(ctx context.Context, command string, out io.Writer) (stackEngine, func(), []reach.Receipt, error) {
	e, err := openEngine(".")
	if err != nil {
		return nil, nil, nil, engineFailure(err)
	}
	unlock, err := e.Lock(command)
	if err != nil {
		return nil, nil, nil, engineFailure(err)
	}
	receipts, err := e.Resume(ctx)
	for _, r := range receipts {
		fmt.Fprintln(out, "Recovered: "+describeReceipt(r))
	}
	if err != nil {
		unlock()
		return nil, nil, nil, engineFailure(err)
	}
	return e, unlock, receipts, nil
}

// refuseUnfinished refuses while recovery left an operation unfinished
// (receipt state accepted, as an uncertain stop leaves it): its stack is in
// no known state, so a command that runs docker of its own starts nothing.
func refuseUnfinished(receipts []reach.Receipt) error {
	for _, r := range receipts {
		if r.State != "accepted" {
			continue
		}
		if err := receiptFailure(r); err != nil {
			return err
		}
		return fmt.Errorf("%s Nothing was done; run 'cyfr reach --resume' to finish it", describeReceipt(r))
	}
	return nil
}

// operationNames are what each operation a receipt answers is called.
var operationNames = map[string]string{
	"switch":  "The change of how this home is reached",
	"join":    "Joining the tailnet",
	"cancel":  "Cancelling a tailnet join",
	"restart": "The restart",
}

// outcomeWords are how a completed operation ended.
var outcomeWords = map[string]string{
	"ok":                "done",
	outcomeStartedLocal: "started on this machine only",
	"rolled_back":       "rolled back",
	"not_applied":       "not applied",
	"failed":            "failed",
}

// describeReceipt is a receipt as a person reads it: the operation and its
// request id, how it stands, and the sentence of the refusal it answers.
func describeReceipt(r reach.Receipt) string {
	name, ok := operationNames[r.Op]
	if !ok {
		name = "The operation " + r.Op
	}
	var how string
	switch r.State {
	case "rejected":
		how = "was refused, and nothing changed"
	case "accepted":
		how = "is unfinished (" + r.Phase + ")"
	case "completed":
		how = outcomeWords[r.Outcome]
		if how == "" {
			how = r.Outcome
		}
		how = "is " + how
	default:
		how = "is " + r.State
	}
	line := fmt.Sprintf("%s (request %s) %s.", name, r.RequestID, how)
	if ref := receiptRefusal(r); ref != nil {
		line += " " + ref.Message()
	}
	return line
}

// requestIDPattern is a request id: 32 lowercase hexadecimal characters.
var requestIDPattern = regexp.MustCompile(`^[0-9a-f]{32}$`)

// newRequestID mints the request id of one invocation.
func newRequestID() (string, error) {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

// joinRequestID is the request id of the join a switch's request id id
// makes, derived from it: a request resent under its id resends its join
// under the same one.
func joinRequestID(id string) string {
	sum := sha256.Sum256([]byte("join\n" + id))
	return hex.EncodeToString(sum[:16])
}

// The terminal init and reach ask their questions on: whether there is
// one (--no-interactive and CYFR_NO_INTERACTIVE say there is not) and its
// input. Tests stand in for both.
var (
	askTerminal           = func() bool { return prompt.IsInteractive(flagNoInteractive) }
	askInput    io.Reader = os.Stdin
)

// reachOptions are the inputs `cyfr init` and `cyfr reach` take for the
// mode they apply.
type reachOptions struct {
	domain, acmeEmail, keyFile, hostname string
	newNode                              bool
}

// addReachFlags adds the flags of the mode a command applies.
func addReachFlags(c *cobra.Command) {
	c.Flags().String("domain", "", "The domain a public home is reached at; its DNS names this machine")
	c.Flags().String("acme-email", "", "The email a public home's certificate authority writes to (optional)")
	c.Flags().String("tailscale-auth-key-file", "", "A file holding a Tailscale auth key, which joins this machine to the tailnet without the approval link")
	c.Flags().String("hostname", "", "This machine's name on the tailnet (cyfr when not given); certificate names are public")
}

func reachFlags(c *cobra.Command) reachOptions {
	var o reachOptions
	o.domain, _ = c.Flags().GetString("domain")
	o.acmeEmail, _ = c.Flags().GetString("acme-email")
	o.keyFile, _ = c.Flags().GetString("tailscale-auth-key-file")
	o.hostname, _ = c.Flags().GetString("hostname")
	if c.Flags().Lookup("new-node") != nil {
		o.newNode, _ = c.Flags().GetBool("new-node")
	}
	return o
}

// checkTailnetOptions refuses a tailnet option given for another mode.
func checkTailnetOptions(mode string, o reachOptions) error {
	for _, option := range []struct {
		name  string
		given bool
	}{{"--tailscale-auth-key-file", o.keyFile != ""}, {"--hostname", o.hostname != ""}, {"--new-node", o.newNode}} {
		if option.given && mode != reach.ModeTailnet {
			return fmt.Errorf("`%s` is for joining a tailnet, and this command chooses `%s`. Nothing was changed. Run it again without `%s`, or run `cyfr reach tailnet` with it", option.name, mode, option.name)
		}
	}
	return nil
}

// readAuthKey reads the Tailscale auth key in the file at path, which
// reaches the engine's join alone and is never printed.
func readAuthKey(path string) ([]byte, error) {
	if path == "" {
		return nil, nil
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("the Tailscale auth key file does not read (%v). Nothing was changed", err)
	}
	key := bytes.TrimSpace(data)
	if len(key) == 0 || bytes.ContainsAny(key, "\r\n") {
		return nil, fmt.Errorf("%s holds no Tailscale auth key: it must hold one key on one line. Nothing was changed", path)
	}
	return key, nil
}

// joinTailnet runs the engine's join under request id, printing the
// approval link while it waits for one, and answers the join id of the
// joined machine. An interrupt cancels the waiting join, whose container
// outlives this command otherwise, and answers tailnet_join_cancelled.
func joinTailnet(ctx context.Context, e stackEngine, id string, o reachOptions, key []byte, out io.Writer) (string, error) {
	req := reach.JoinRequest{
		ID:       id,
		Hostname: o.hostname,
		NewNode:  o.newNode,
		OnAuthURL: func(url string) {
			fmt.Fprintf(out, "To join this machine to your tailnet, open this link and approve the machine:\n  %s\nWaiting for the approval (Ctrl-C cancels the join)...\n", url)
		},
	}
	if key != nil {
		req.AuthKey = bytes.NewReader(key)
	}
	rec, err := e.Join(ctx, req)
	if ctx.Err() != nil {
		if err == nil && receiptFailure(rec) == nil {
			return "", fmt.Errorf("the join was interrupted after the machine joined your tailnet as %s; how this home is reached was not changed, and 'cyfr reach tailnet' takes the machine as it is", rec.Payload["name"])
		}
		if cerr := e.CancelWaitingJoin(context.WithoutCancel(ctx)); cerr != nil {
			return "", fmt.Errorf("the join was interrupted, and cancelling it failed (%v), so its container may wait until its own deadline before it ends; how this home is reached was not changed", engineFailure(cerr))
		}
		return "", refusalError{reach.Refuse("tailnet_join_cancelled", nil)}
	}
	if err != nil {
		return "", engineFailure(err)
	}
	if err := receiptFailure(rec); err != nil {
		return "", err
	}
	joinID := rec.Payload["join_id"]
	if joinID == "" {
		return "", fmt.Errorf("the join answered no join id (%s); how this home is reached was not changed", describeReceipt(rec))
	}
	if name := rec.Payload["name"]; name != "" {
		fmt.Fprintf(out, "This machine is on your tailnet as %s.\n", name)
	}
	return joinID, nil
}

// previewTarget is the engine's preview of target: for tailnet, from the
// machine as it is joined, joining it first (joinTailnet, under the join's
// request id) when it is not, or when --new-node replaces its identity.
func previewTarget(ctx context.Context, e stackEngine, target reach.Target, id string, o reachOptions, key []byte, out io.Writer) (reach.Preview, string, error) {
	if target.Mode != reach.ModeTailnet {
		p, err := e.Preview(ctx, target, "")
		return p, "", engineFailure(err)
	}
	if !o.newNode {
		p, err := e.Preview(ctx, target, "")
		var r *reach.Refusal
		if !errors.As(err, &r) || r.Code != "tailnet_not_joined" {
			return p, "", engineFailure(err)
		}
	}
	joinID, err := joinTailnet(ctx, e, joinRequestID(id), o, key, out)
	if err != nil {
		return reach.Preview{}, "", err
	}
	p, err := e.Preview(ctx, target, joinID)
	return p, joinID, engineFailure(err)
}

// printPreview prints a change before it is made: each of the words as
// before → after, then what the person must do when the address changes.
func printPreview(out io.Writer, p reach.Preview) {
	fmt.Fprintln(out, "This changes how this home is reached:")
	before, after := p.OldWords.Sentences(), p.NewWords.Sentences()
	for i := range before {
		label, old, _ := strings.Cut(before[i], ": ")
		_, now, _ := strings.Cut(after[i], ": ")
		fmt.Fprintf(out, "  %s: %s → %s\n", label, old, now)
	}
	if len(p.AddressChanges) > 0 {
		fmt.Fprintln(out, "The address changes, so:")
		for i, change := range p.AddressChanges {
			fmt.Fprintf(out, "  %d. %s\n", i+1, change)
		}
		fmt.Fprintln(out, "Your CYFR identity does not change.")
	}
}

// printWords prints the words a head reads as, indented.
func printWords(out io.Writer, w reach.Words) {
	for _, line := range w.Sentences() {
		fmt.Fprintln(out, "  "+line)
	}
}

func init() {
	addReachFlags(reachCmd)
	reachCmd.Flags().Bool("new-node", false, "Replace this machine's tailnet identity before joining, so the home can take another name")
	reachCmd.Flags().Bool("yes", false, "Make the change without asking to confirm it")
	reachCmd.Flags().Bool("resume", false, "Finish an interrupted change under the lock and report what happened")
	reachCmd.Flags().String("request-id", "", "The request id, 32 lowercase hexadecimal characters (minted when not given)")
	_ = reachCmd.Flags().MarkHidden("request-id")
	reachCmd.AddCommand(reachStatusCmd)
	rootCmd.AddCommand(reachCmd)
}

var reachCmd = &cobra.Command{
	Use:     "reach <local|tailnet|public>",
	Short:   "Choose how this home is reached: this computer only, your tailnet, or a public domain",
	GroupID: "server",
	Long: `Change how the home in the current directory is reached, and every setting that follows from it in .env (CYFR_REACH, CYFR_HOST, CYFR_PUBLIC_URL, CYFR_TAILNET_NODE_ID, CADDY_ACME_EMAIL).

  local    this computer only, at http://localhost:<CYFR_PORT>
  tailnet  your devices on Tailscale, at https://<machine>.<tailnet>.ts.net; the machine joins your tailnet first (the link it prints approves it, or --tailscale-auth-key-file joins it without one)
  public   anyone on the internet, who still has to sign in, at https://<--domain>, through Caddy on ports 80 and 443

It shows the change first: who can reach the home, its address, the certificate email and the ports opened on this machine, each before → after, and what changes for passkeys, paired devices and clients when the address does. Confirm it (or pass --yes), and the stack is stopped and checked stopped, .env is rewritten, and what was running is started again in the new mode; a start that fails puts the home back as it was.

'cyfr reach status' shows how the home is reached and what runs, changing nothing. 'cyfr reach --resume' finishes a change an interrupted command left, under the lock, and reports what happened; it is what to run after an interruption.

Exit status 3: the change was made and the home started, but on this machine only, because the machine's tailnet identity is not the one .env now names; Serve stays closed, and the message says to run 'cyfr reach tailnet'. A refused or failed change exits 1.`,
	Example: `  cyfr reach tailnet
  cyfr reach public --domain cyfr.example.com --acme-email ops@example.com
  cyfr reach local --yes
  cyfr reach --resume
  cyfr reach status`,
	Args: cobra.MaximumNArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		ctx := cmd.Context()
		if ctx == nil {
			ctx = context.Background()
		}
		resume, _ := cmd.Flags().GetBool("resume")
		if resume {
			if len(args) > 0 {
				return errors.New("cyfr reach --resume names no mode: it finishes the change already begun")
			}
			return runReachResume(ctx, cmd.OutOrStdout())
		}
		if len(args) == 0 {
			return errors.New("name the mode: cyfr reach local, cyfr reach tailnet or cyfr reach public (cyfr reach status shows the current one)")
		}
		yes, _ := cmd.Flags().GetBool("yes")
		id, _ := cmd.Flags().GetString("request-id")
		return runReach(ctx, args[0], reachFlags(cmd), yes, id, cmd.OutOrStdout())
	},
}

var reachStatusCmd = &cobra.Command{
	Use:   "status",
	Short: "Show how this home is reached and what runs, changing nothing",
	Long:  "Show how the home in the current directory is reached, as .env says, the stack's containers, the health of the mode's proxy, a change left unfinished and the last change's outcome. It takes no lock and changes nothing, so it answers while another command runs.",
	Args:  cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		ctx := cmd.Context()
		if ctx == nil {
			ctx = context.Background()
		}
		return runReachStatus(ctx, cmd.OutOrStdout())
	},
}

// runReach is `cyfr reach <mode>`: the preview, the confirmation, then the
// switch under the lock, for tailnet with the join first.
func runReach(ctx context.Context, mode string, o reachOptions, yes bool, id string, out io.Writer) error {
	if mode != reach.ModeLocal && mode != reach.ModeTailnet && mode != reach.ModePublic {
		return fmt.Errorf("cyfr reach takes local, tailnet or public; %q is none of them", mode)
	}
	if err := checkTailnetOptions(mode, o); err != nil {
		return err
	}
	if id == "" {
		var err error
		if id, err = newRequestID(); err != nil {
			return err
		}
	} else if !requestIDPattern.MatchString(id) {
		return fmt.Errorf("--request-id %q is not 32 lowercase hexadecimal characters", id)
	}
	interactive := askTerminal()
	if !yes && !interactive {
		return errors.New("cyfr reach makes the change it shows only once it is confirmed: run it on a terminal, or with --yes. Nothing was changed")
	}
	key, err := readAuthKey(o.keyFile)
	if err != nil {
		return err
	}

	e, unlock, _, err := openLocked(ctx, "reach "+mode, out)
	if err != nil {
		return err
	}
	defer unlock()

	target := reach.Target{Mode: mode, Domain: o.domain, ACMEEmail: o.acmeEmail}
	p, joinID, err := previewTarget(ctx, e, target, id, o, key, out)
	if err != nil {
		return err
	}
	printPreview(out, p)
	if !yes {
		answer := ask(bufio.NewReader(askInput), out, "Make this change? (yes/no)", "no")
		if a := strings.ToLower(answer); a != "yes" && a != "y" {
			return errors.New("the change was not confirmed. Nothing was changed")
		}
	}

	// The switch runs to its end once it begins: an interrupt then is the
	// journal's to recover, never a half-made change this command walks
	// away from.
	rec, err := e.Switch(context.WithoutCancel(ctx), reach.SwitchRequest{
		ID: id, Target: target, JoinID: joinID, OldDigest: p.OldDigest, NewDigest: p.NewDigest,
	})
	if err != nil {
		return engineFailure(err)
	}
	if err := receiptFailure(rec); err != nil {
		return err
	}
	fmt.Fprintln(out, "Done. This home is reached as:")
	printWords(out, p.NewWords)
	return nil
}

// runReachResume is `cyfr reach --resume`: the lock and recovery, then the
// report. A change recovery could not finish is a failure, its sentence
// saying what to do next.
func runReachResume(ctx context.Context, out io.Writer) error {
	_, unlock, receipts, err := openLocked(ctx, "reach --resume", out)
	if err != nil {
		return err
	}
	defer unlock()
	if len(receipts) == 0 {
		fmt.Fprintln(out, "Nothing was unfinished: this home is as .env says.")
	}
	return refuseUnfinished(receipts)
}

// runReachStatus is `cyfr reach status`: the engine's status, read without
// the lock.
func runReachStatus(ctx context.Context, out io.Writer) error {
	e, err := openEngine(".")
	if err != nil {
		return engineFailure(err)
	}
	st, err := e.Status(ctx)
	if err != nil {
		return engineFailure(err)
	}
	if st.HeadErr != nil {
		fmt.Fprintln(out, ".env says no coherent way this home is reached: "+engineFailure(st.HeadErr).Error())
	} else {
		fmt.Fprintln(out, "This home is reached as .env says:")
		printWords(out, st.Words)
	}
	if len(st.Containers) == 0 {
		fmt.Fprintln(out, "Nothing of the stack runs.")
	} else {
		fmt.Fprintln(out, "Containers:")
		for _, c := range st.Containers {
			fmt.Fprintf(out, "  %s (%s): %s\n", c.Service, c.Name, c.State)
		}
	}
	for _, line := range st.Health {
		fmt.Fprintln(out, "  "+line)
	}
	if st.Unfinished != nil {
		fmt.Fprintln(out, "Unfinished: "+describeReceipt(*st.Unfinished))
	}
	if st.Last != nil {
		fmt.Fprintf(out, "Last change, %s: %s\n", st.Last.At.UTC().Format(time.RFC3339), describeReceipt(*st.Last))
	}
	return nil
}
