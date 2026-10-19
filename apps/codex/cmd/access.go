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

	"github.com/cyfr/codex/internal/access"
	"github.com/cyfr/codex/internal/prompt"
	"github.com/spf13/cobra"
)

// stackEngine is the access engine (access.Engine) as the commands that
// start, stop, change or read the stack use it. It owns the project's
// lock, its recovery, every docker call made under the lock and the access
// keys of .env.
type stackEngine interface {
	Lock(holder string) (func(), error)
	Resume(ctx context.Context) ([]access.Receipt, error)
	Docker() access.Docker
	Redactor() *access.Redactor
	ComposeArgs(ctx context.Context, h access.Head, args ...string) ([]string, error)
	Head() (access.Head, error)
	CheckStack(ctx context.Context) error
	Status(ctx context.Context) (access.Status, error)
	Preview(ctx context.Context, t access.Target, joinID string) (access.Preview, error)
	Switch(ctx context.Context, r access.SwitchRequest) (access.Receipt, error)
	Join(ctx context.Context, r access.JoinRequest) (access.Receipt, error)
	CancelWaitingJoin(ctx context.Context) error
	ForgetJoin() error
	Start(ctx context.Context, cause string) (access.Receipt, error)
	StartWithin(ctx context.Context, cause string, health time.Duration) (access.Receipt, error)
	Stop(ctx context.Context, cause string, all bool) (access.Receipt, error)
	CloseServe(ctx context.Context) error
	Resent(id string, c access.RequestContent) (access.Receipt, bool, error)
}

// openEngine opens the engine of the project at dir; its recovery, starts,
// switches and joins refuse a .env that sets a COMPOSE_* key before any
// docker call. A variable so a test stands in a fake engine.
var openEngine = func(dir string) (stackEngine, error) {
	e, err := access.Open(dir, nil)
	if err != nil {
		return nil, err
	}
	return e, nil
}

// refusalError is a refusal as a command's failure: Execute prints its
// sentence, and the command exits non-zero.
type refusalError struct{ r *access.Refusal }

func (e refusalError) Error() string { return e.r.Message() }
func (e refusalError) Unwrap() error { return e.r }

// engineFailure is err as a command reports it: a refusal, the lock's
// included, by its sentence, anything else as it is.
func engineFailure(err error) error {
	var busy *access.ErrBusy
	if errors.As(err, &busy) {
		if r := busy.Refusal(); r != nil {
			return refusalError{r}
		}
	}
	var r *access.Refusal
	if errors.As(err, &r) {
		return refusalError{r}
	}
	return err
}

// answerFailure is the failure an engine method's answer means, its
// receipt and its error together: the engine answers a receipt that
// carries a code with that code's refusal as the error. A start that left
// the home on this machine alone (outcome started_local) is startedLocally
// whatever the error says; any other error is that failure, a refusal by
// its sentence; otherwise the receipt's own refusal, nil for a success.
func answerFailure(rec access.Receipt, err error) error {
	if rec.Outcome == outcomeStartedLocal {
		return receiptFailure(rec)
	}
	if err != nil {
		return engineFailure(err)
	}
	return receiptFailure(rec)
}

// outcomeStartedLocal is the outcome of a start that started the home on
// this machine alone: the tailnet machine is not ready to serve it (not
// the one .env names, not joined, or HTTPS off), so Serve stays closed, and
// the receipt answers the refusal that says which.
const outcomeStartedLocal = "started_local"

// startedLocally is a start that left the home running on this machine
// alone (outcomeStartedLocal), whatever refusal says why. It is no
// success: its sentence says what to do, and the process exits 3
// (ExitStatus), apart from a start that failed.
type startedLocally struct{ refusalError }

// receiptFailure is the failure a receipt answers, nil for a plain
// success; a start that left the home on this machine alone answers
// startedLocally, by its outcome alone.
func receiptFailure(rec access.Receipt) error {
	r := rec.Refusal()
	if rec.Outcome == outcomeStartedLocal {
		if r == nil {
			r = access.Refuse(rec.Code, rec.Payload)
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
func openLocked(ctx context.Context, command string, out io.Writer) (stackEngine, func(), []access.Receipt, error) {
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
func refuseUnfinished(receipts []access.Receipt) error {
	for _, r := range receipts {
		if r.State != "accepted" {
			continue
		}
		if err := receiptFailure(r); err != nil {
			return err
		}
		return fmt.Errorf("%s Nothing was done; run `cyfr access --resume` to finish it", describeReceipt(r))
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
func describeReceipt(r access.Receipt) string {
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
	if ref := r.Refusal(); ref != nil {
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

// accessOptions are the inputs `cyfr init` and `cyfr access` take for the
// mode they apply.
type accessOptions struct {
	domain, acmeEmail, keyFile, hostname string
	newNode                              bool
}

// addAccessFlags adds the flags of the mode a command applies.
func addAccessFlags(c *cobra.Command) {
	c.Flags().String("domain", "", "The domain a public home is reached at; its DNS names this machine")
	c.Flags().String("acme-email", "", "The email a public home's certificate authority writes to (optional)")
	c.Flags().String("tailscale-auth-key-file", "", "A file holding a Tailscale auth key, which joins this machine to the tailnet without the approval link")
	c.Flags().String("hostname", "", "This machine's name on the tailnet (cyfr when not given); certificate names are public")
}

func accessFlags(c *cobra.Command) accessOptions {
	var o accessOptions
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
func checkTailnetOptions(mode string, o accessOptions) error {
	for _, option := range []struct {
		name  string
		given bool
	}{{"--tailscale-auth-key-file", o.keyFile != ""}, {"--hostname", o.hostname != ""}, {"--new-node", o.newNode}} {
		if option.given && mode != access.ModeTailnet {
			return fmt.Errorf("`%s` is for joining a tailnet, and this command chooses `%s`. Nothing was changed. Run it again without `%s`, or run `cyfr access tailnet` with it", option.name, mode, option.name)
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
func joinTailnet(ctx context.Context, e stackEngine, id string, o accessOptions, key []byte, out io.Writer) (string, error) {
	req := access.JoinRequest{
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
			return "", fmt.Errorf("the join was interrupted after the machine joined your tailnet as %s; how this home is reached was not changed, and `cyfr access tailnet` takes the machine as it is", rec.Payload["name"])
		}
		if cerr := e.CancelWaitingJoin(context.WithoutCancel(ctx)); cerr != nil {
			return "", fmt.Errorf("the join was interrupted, and cancelling it failed (%v), so its container may wait until its own deadline before it ends; how this home is reached was not changed", engineFailure(cerr))
		}
		return "", refusalError{access.Refuse("tailnet_join_cancelled", nil)}
	}
	if err := answerFailure(rec, err); err != nil {
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

// joinChoice is how a command meets the join its preview needs. confirm,
// when set, is asked before the join starts, with the name of the machine
// --new-node replaces ("" when previewTarget names none), and its error
// refuses the join; optionsGiven says --hostname or
// --tailscale-auth-key-file was given, which apply to a new join alone.
type joinChoice struct {
	confirm      func(current string) error
	optionsGiven bool
}

// joined is the join a preview made: its id, "" when the preview needed
// none, and the name of the machine its --new-node join replaced, "" unless
// the engine knew this home had that machine, .env agreeing, and the join
// answered another node.
type joined struct {
	id, removed string
}

// previewTarget is the engine's preview of target: for tailnet, from the
// machine as it is joined, joining it first (joinTailnet, under the join's
// request id) when it is not, or when --new-node replaces its identity,
// and answering the join. The join is what changes the tailnet, so it is
// confirmed before it starts; a machine already joined refuses the
// options of a new join rather than ignore them.
func previewTarget(ctx context.Context, e stackEngine, target access.Target, id string, o accessOptions, key []byte, out io.Writer, choice joinChoice) (access.Preview, joined, error) {
	p, err := e.Preview(ctx, target, "")
	if target.Mode != access.ModeTailnet {
		return p, joined{}, engineFailure(err)
	}
	var r *access.Refusal
	notJoined := errors.As(err, &r) && r.Code == "tailnet_not_joined"
	switch {
	case err == nil && !o.newNode:
		if choice.optionsGiven {
			return access.Preview{}, joined{}, alreadyJoined(p.New.Host, o)
		}
		return p, joined{}, nil
	case err != nil && !notJoined && (!o.newNode || r == nil || r.Code == "tailnet_active"):
		return access.Preview{}, joined{}, engineFailure(err)
	}
	// The machine a new node replaces is the engine's own read of this
	// home's machine (the running tailscale service's, else the latest
	// completed join's), named only where .env agrees with it: .env's head
	// names no machine (local or public) or the same node. A tailnet .env
	// naming another node (a restore leaves the machine's state and its
	// last join as they were) or a .env whose head does not read names
	// none, and nor does any refusal but access_unchanged: that one derived
	// .env's own head from the engine's machine, so the machine's name and
	// node id are .env's by the engine's read.
	var known access.Head
	switch {
	case !o.newNode:
	case err == nil:
		switch p.Old.Mode {
		case access.ModeLocal, access.ModePublic:
			known = p.New
		case access.ModeTailnet:
			if p.Old.NodeID == p.New.NodeID {
				known = p.New
			}
		}
	case r != nil && r.Code == "access_unchanged":
		if h, herr := e.Head(); herr == nil && h.Mode == access.ModeTailnet {
			known = h
		}
	}
	if choice.confirm != nil {
		if err := choice.confirm(known.Host); err != nil {
			return access.Preview{}, joined{}, err
		}
	}
	joinID, err := joinTailnet(ctx, e, joinRequestID(id), o, key, out)
	if err != nil {
		return access.Preview{}, joined{}, err
	}
	p, err = e.Preview(ctx, target, joinID)
	if err != nil {
		return p, joined{id: joinID}, engineFailure(err)
	}
	removed := ""
	if known.Host != "" && known.NodeID != p.New.NodeID {
		removed = known.Host
	}
	return p, joined{id: joinID, removed: removed}, nil
}

// alreadyJoined refuses the options of a new join for a machine already on
// the tailnet as name.
func alreadyJoined(name string, o accessOptions) error {
	var given []string
	if o.hostname != "" {
		given = append(given, "`--hostname`")
	}
	if o.keyFile != "" {
		given = append(given, "`--tailscale-auth-key-file`")
	}
	return fmt.Errorf("This machine is already on your tailnet as `%s`, and %s %s for a new join. Nothing was changed. Run `cyfr access tailnet --new-node` with %s to replace its tailnet identity, or run it again without %s", name, joinNames(given), plural(given, "is", "are"), plural(given, "it", "them"), plural(given, "it", "them"))
}

// joinName is the name a join asks the tailnet for.
func joinName(o accessOptions) string {
	if o.hostname != "" {
		return o.hostname
	}
	return "cyfr"
}

// askJoin asks on the terminal whether to make the join a change needs,
// naming what it does: with --new-node, the tailnet identity it removes
// first.
func askJoin(in *bufio.Reader, out io.Writer, o accessOptions) func(current string) error {
	return func(current string) error {
		what := fmt.Sprintf("This joins this machine to your tailnet as `%s`; certificate names are public", joinName(o))
		if o.newNode {
			removed := "if it has one"
			if current != "" {
				removed = fmt.Sprintf("`%s`, which the Tailscale admin console still lists until you remove it there", current)
			}
			what = fmt.Sprintf("This joins this machine to your tailnet as `%s`, after removing its current tailnet identity, %s; certificate names are public", joinName(o), removed)
		}
		fmt.Fprintln(out, what+".")
		if a := strings.ToLower(ask(in, out, "Join it? (yes/no)", "no")); a != "yes" && a != "y" {
			return errors.New("The join was not confirmed, so this machine did not join your tailnet. Nothing was changed")
		}
		return nil
	}
}

// requestContent is everything a `cyfr access` command was asked, which
// the engine binds its request id to (access.RequestContent).
func requestContent(target access.Target, o accessOptions, key []byte) access.RequestContent {
	return access.RequestContent{
		Mode: target.Mode, Domain: target.Domain, ACMEEmail: target.ACMEEmail,
		Hostname: o.hostname, NewNode: o.newNode, AuthKeyFingerprint: access.AuthKeyFingerprint(key),
	}
}

// answerResent answers a request id the engine already holds the receipt
// of, or the unfinished operation of, as the request answered when it was
// first sent, the same sentence and the same exit status, and does
// nothing else; sent is false when it holds neither. The engine binds the
// id to what it was first asked (Resent): asked anything else under it, a
// target or join inputs of another request, it is access_request_reused,
// whatever the first request's outcome.
func answerResent(c access.RequestContent, id string, out io.Writer) (sent bool, err error) {
	e, err := openEngine(".")
	if err != nil {
		return true, engineFailure(err)
	}
	rec, ok, err := e.Resent(id, c)
	if err != nil {
		return true, engineFailure(err)
	}
	if !ok {
		return false, nil
	}
	switch {
	case rec.Op != "switch":
		return true, refusalError{access.Refuse("access_request_reused", nil)}
	case rec.State == "accepted":
		return true, refuseUnfinished([]access.Receipt{rec})
	}
	// A receipt read back carries its refusal in itself, with no error
	// beside it.
	if err := answerFailure(rec, nil); err != nil {
		return true, err
	}
	if rec.FinalHead != nil {
		fmt.Fprintln(out, "Done. This home is reached as:")
		printWords(out, access.Describe(*rec.FinalHead))
	}
	return true, nil
}

// printPreview prints a change before it is made: each of the words as
// before → after, then each change they do not show (unwordedChanges),
// then what the person must do when the address changes. A reopen, the
// tailnet head .env holds already with Serve closed, is the home served on
// the tailnet again.
func printPreview(out io.Writer, p access.Preview) {
	if p.Reopen {
		// The head is .env's already: what changes is that the home is
		// served on the tailnet again, once the machine is checked.
		fmt.Fprintf(out, "Tailscale Serve is closed, so this home answers on this machine only. This checks the machine again and serves the home on your tailnet at %s:\n", p.NewWords.Address)
		printWords(out, p.NewWords)
		return
	}
	fmt.Fprintln(out, "This changes how this home is reached:")
	before, after := p.OldWords.Sentences(), p.NewWords.Sentences()
	for i := range before {
		label, old, _ := strings.Cut(before[i], ": ")
		_, now, _ := strings.Cut(after[i], ": ")
		fmt.Fprintf(out, "  %s: %s → %s\n", label, old, now)
	}
	for _, line := range unwordedChanges(p.Old, p.New) {
		fmt.Fprintln(out, "  "+line)
	}
	if len(p.AddressChanges) > 0 {
		fmt.Fprintln(out, "The address changes, so:")
		for i, change := range p.AddressChanges {
			fmt.Fprintf(out, "  %d. %s\n", i+1, change)
		}
		fmt.Fprintln(out, "Your CYFR identity does not change.")
	}
}

// unwordedChanges are the head's changes the four sentences do not show,
// each as before → after: the tailnet machine (its name and node id), the
// port of cyfr's listener on this computer and the builds service.
func unwordedChanges(old, next access.Head) []string {
	machine := func(h access.Head) string {
		if h.NodeID == "" {
			return "none"
		}
		return h.Host + " (" + h.NodeID + ")"
	}
	builds := func(h access.Head) string {
		if h.BuildsURL == "" {
			return "off"
		}
		return h.BuildsURL
	}
	var lines []string
	if old.NodeID != next.NodeID {
		lines = append(lines, "Tailnet machine: "+machine(old)+" → "+machine(next))
	}
	if old.Port != next.Port {
		lines = append(lines, fmt.Sprintf("Port on this computer: %d → %d", old.Port, next.Port))
	}
	if old.BuildsURL != next.BuildsURL {
		lines = append(lines, "Builds service: "+builds(old)+" → "+builds(next))
	}
	return lines
}

// printWords prints the words a head reads as, indented.
func printWords(out io.Writer, w access.Words) {
	for _, line := range w.Sentences() {
		fmt.Fprintln(out, "  "+line)
	}
}

func init() {
	addAccessFlags(accessCmd)
	accessCmd.Flags().Bool("new-node", false, "Replace this machine's tailnet identity before joining, so the home can take another name")
	accessCmd.Flags().Bool("yes", false, "Make the change without asking to confirm it")
	accessCmd.Flags().Bool("resume", false, "Finish an interrupted change under the lock and report what happened")
	accessCmd.Flags().String("request-id", "", "The request id, 32 lowercase hexadecimal characters (minted when not given)")
	_ = accessCmd.Flags().MarkHidden("request-id")
	accessCmd.AddCommand(accessStatusCmd)
	rootCmd.AddCommand(accessCmd)
}

var accessCmd = &cobra.Command{
	Use:     "access <local|tailnet|public>",
	Short:   "Choose how this home is reached: this computer only, your tailnet, or a public domain",
	GroupID: "server",
	Long: `Change how the home in the current directory is reached, and every setting that follows from it in .env (CYFR_ACCESS, CYFR_HOST, CYFR_PUBLIC_URL, CYFR_TAILNET_NODE_ID, CADDY_ACME_EMAIL).

  local    this computer only, at http://localhost:<CYFR_PORT>
  tailnet  your devices on Tailscale, at https://<machine>.<tailnet>.ts.net; the machine joins your tailnet first (the link it prints approves it, or --tailscale-auth-key-file joins it without one)
  public   anyone on the internet, who still has to sign in, at https://<--domain>, through Caddy on ports 80 and 443

It shows the change first: who can reach the home, its address, the certificate email and the ports opened on this machine, each before → after, with the tailnet machine, the port on this computer and the builds service when they change, and what changes for passkeys, paired devices and clients when the address does. Confirm it (or pass --yes), and the stack is stopped and checked stopped, .env is rewritten, and what was running is started again in the new mode; a start that fails puts the home back as it was. With no terminal to confirm on and no --yes, it shows the change and makes none, and a tailnet change that needs this machine joined first is refused before the join.

A tailnet home whose Tailscale Serve is closed, because the machine was not ready when it started (HTTPS certificates off, say), is served on the tailnet again by 'cyfr access tailnet': it shows that, and once confirmed checks the machine again and opens Serve without stopping anything or rewriting .env.

'cyfr access status' shows how the home is reached and what runs, changing nothing. 'cyfr access --resume' finishes a change an interrupted command left, under the lock, and reports what happened; it is what to run after an interruption.

Exit status 3: the change was made and the home started, but on this machine only, because the tailnet machine is not ready to serve it (not the one .env now names, not joined, or HTTPS off); Serve stays closed, and the message says what to do. A refused or failed change exits 1.`,
	Example: `  cyfr access tailnet
  cyfr access public --domain cyfr.example.com --acme-email ops@example.com
  cyfr access local --yes
  cyfr access --resume
  cyfr access status`,
	Args: cobra.MaximumNArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		ctx := cmd.Context()
		if ctx == nil {
			ctx = context.Background()
		}
		resume, _ := cmd.Flags().GetBool("resume")
		if resume {
			if len(args) > 0 {
				return errors.New("cyfr access --resume names no mode: it finishes the change already begun")
			}
			return runAccessResume(ctx, cmd.OutOrStdout())
		}
		if len(args) == 0 {
			return errors.New("name the mode: cyfr access local, cyfr access tailnet or cyfr access public (cyfr access status shows the current one)")
		}
		yes, _ := cmd.Flags().GetBool("yes")
		id, _ := cmd.Flags().GetString("request-id")
		return runAccess(ctx, args[0], accessFlags(cmd), yes, id, cmd.OutOrStdout())
	},
}

var accessStatusCmd = &cobra.Command{
	Use:   "status",
	Short: "Show how this home is reached and what runs, changing nothing",
	Long:  "Show how the home in the current directory is reached, as .env says, the stack's containers, the health of the mode's proxy, a change left unfinished and the last change's outcome. It takes no lock and changes nothing, so it answers while another command runs.",
	Args:  cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		ctx := cmd.Context()
		if ctx == nil {
			ctx = context.Background()
		}
		return runAccessStatus(ctx, cmd.OutOrStdout())
	},
}

// runAccess is `cyfr access <mode>`: the preview, the confirmation, then the
// switch under the lock, for tailnet with the join first.
func runAccess(ctx context.Context, mode string, o accessOptions, yes bool, id string, out io.Writer) error {
	if mode != access.ModeLocal && mode != access.ModeTailnet && mode != access.ModePublic {
		return fmt.Errorf("cyfr access takes local, tailnet or public; %q is none of them", mode)
	}
	if err := checkTailnetOptions(mode, o); err != nil {
		return err
	}
	target := access.Target{Mode: mode, Domain: o.domain, ACMEEmail: o.acmeEmail}
	resent := id != ""
	if resent && !requestIDPattern.MatchString(id) {
		return fmt.Errorf("--request-id %q is not 32 lowercase hexadecimal characters", id)
	}
	key, err := readAuthKey(o.keyFile)
	if err != nil {
		return err
	}
	content := requestContent(target, o, key)
	if resent {
		if sent, err := answerResent(content, id, out); sent {
			return err
		}
	} else if id, err = newRequestID(); err != nil {
		return err
	}
	if !yes && !askTerminal() {
		return showUnconfirmed(ctx, target, o, out)
	}

	e, unlock, _, err := openLocked(ctx, "access "+mode, out)
	if err != nil {
		return err
	}
	defer unlock()

	in := bufio.NewReader(askInput)
	choice := joinChoice{optionsGiven: o.hostname != "" || o.keyFile != ""}
	if !yes {
		choice.confirm = askJoin(in, out, o)
	}
	p, join, err := previewTarget(ctx, e, target, id, o, key, out, choice)
	if err != nil {
		return err
	}
	printPreview(out, p)
	if !yes {
		if a := strings.ToLower(ask(in, out, "Make this change? (yes/no)", "no")); a != "yes" && a != "y" {
			switch {
			case join.removed != "":
				return fmt.Errorf("The change was not confirmed. This machine's tailnet identity `%s` was removed, and the Tailscale admin console still lists it until you remove it there; the machine joined your tailnet as `%s`, and how this home is reached was not changed", join.removed, p.New.Host)
			case join.id != "":
				return fmt.Errorf("The change was not confirmed. This machine joined your tailnet as `%s`, and how this home is reached was not changed", p.New.Host)
			}
			return errors.New("the change was not confirmed. Nothing was changed")
		}
	}

	// The switch runs to its end once it begins: an interrupt then is the
	// journal's to recover, never a half-made change this command walks
	// away from.
	if err := answerFailure(e.Switch(context.WithoutCancel(ctx), access.SwitchRequest{
		ID: id, Target: target, JoinID: join.id, OldDigest: p.OldDigest, NewDigest: p.NewDigest, Content: content,
	})); err != nil {
		return err
	}
	fmt.Fprintln(out, "Done. This home is reached as:")
	printWords(out, p.NewWords)
	if p.Reopen {
		printTailscale(ctx, e, out)
	}
	return nil
}

// printTailscale prints the tailnet machine as the engine sees it now
// (Status): whether it is connected as the machine .env names, its HTTPS
// certificates and whether Serve is open.
func printTailscale(ctx context.Context, e stackEngine, out io.Writer) {
	st, err := e.Status(ctx)
	if err != nil || len(st.Health) == 0 {
		return
	}
	fmt.Fprintln(out, "Tailscale now:")
	for _, line := range st.Health {
		fmt.Fprintln(out, "  "+line)
	}
}

// showUnconfirmed is `cyfr access <mode>` with no terminal to confirm on and
// no --yes: the change shown when its preview needs no join, read without
// the lock, and refused either way, nothing changed and no input read. A
// preview that needs the machine joined is refused before the join, which
// would change the tailnet.
func showUnconfirmed(ctx context.Context, target access.Target, o accessOptions, out io.Writer) error {
	const again = "Nothing was changed. Run it again with --yes to make the change, or on a terminal to confirm it"
	joinFirst := errors.New("This machine joins your tailnet before the change can be shown, and there is no terminal to confirm it on. " + again)
	if target.Mode == access.ModeTailnet && o.newNode {
		return joinFirst
	}
	e, err := openEngine(".")
	if err != nil {
		return engineFailure(err)
	}
	p, err := e.Preview(ctx, target, "")
	if r := (*access.Refusal)(nil); errors.As(err, &r) && r.Code == "tailnet_not_joined" {
		return joinFirst
	}
	if err != nil {
		return engineFailure(err)
	}
	if target.Mode == access.ModeTailnet && (o.hostname != "" || o.keyFile != "") {
		return alreadyJoined(p.New.Host, o)
	}
	printPreview(out, p)
	return errors.New("The change above was shown, not made: cyfr access makes a change only once it is confirmed, and there is no terminal to confirm it on. " + again)
}

// runAccessResume is `cyfr access --resume`: the lock and recovery, then the
// report. A change recovery could not finish is a failure, its sentence
// saying what to do next; one whose recovery started the home on this
// machine alone is startedLocally, as every start path's is.
func runAccessResume(ctx context.Context, out io.Writer) error {
	_, unlock, receipts, err := openLocked(ctx, "access --resume", out)
	if err != nil {
		return err
	}
	defer unlock()
	if len(receipts) == 0 {
		fmt.Fprintln(out, "Nothing was unfinished: this home is as .env says.")
	}
	if err := refuseUnfinished(receipts); err != nil {
		return err
	}
	// Each recovered receipt carries its refusal in itself, as Resume
	// answers it.
	for _, r := range receipts {
		if err := answerFailure(r, nil); err != nil {
			return err
		}
		if r.Outcome == "failed" || r.Outcome == "rolled_back" {
			return errors.New(describeReceipt(r))
		}
	}
	return nil
}

// runAccessStatus is `cyfr access status`: the engine's status, read without
// the lock.
func runAccessStatus(ctx context.Context, out io.Writer) error {
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
		fmt.Fprintln(out, "Unfinished: "+describeReceipt(*st.Unfinished)+" Run `cyfr access --resume` to finish it.")
	}
	if st.Last != nil {
		fmt.Fprintf(out, "Last change, %s: %s\n", st.Last.At.UTC().Format(time.RFC3339), describeReceipt(*st.Last))
	}
	return nil
}
