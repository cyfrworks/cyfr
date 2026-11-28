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
	"net"
	"os"
	"slices"
	"strings"
	"time"

	"github.com/cyfr/codex/internal/access"
	"github.com/cyfr/codex/internal/prompt"
	"github.com/cyfr/codex/internal/setup"
	"github.com/spf13/cobra"
)

// stackEngine is the access engine (access.Engine) as the commands that
// start, stop, change or read the stack use it. It owns the project's
// lock, its recovery, every docker call made under the lock and the access
// settings of .env.
type stackEngine interface {
	Lock(holder string) (func(), error)
	Resume(ctx context.Context) ([]access.Receipt, error)
	Docker() access.Docker
	Redactor() *access.Redactor
	ComposeArgs(ctx context.Context, h access.Head, args ...string) ([]string, error)
	DeclaredProfiles(ctx context.Context) ([]string, error)
	Head() (access.Head, error)
	Words() (access.Words, error)
	CheckStack(ctx context.Context) error
	Status(ctx context.Context) (access.Status, error)
	Preview(ctx context.Context, t access.Target, joinID string) (access.Preview, error)
	Switch(ctx context.Context, r access.SwitchRequest) (access.Receipt, error)
	Join(ctx context.Context, r access.JoinRequest) (access.Receipt, error)
	CancelWaitingJoin(ctx context.Context) error
	Hold(cause string) error
	Release() error
	ForgetJoin() error
	Start(ctx context.Context, cause string) (access.Receipt, error)
	StartWithin(ctx context.Context, cause string, health time.Duration) (access.Receipt, error)
	Stop(ctx context.Context, cause string, all bool) (access.Receipt, error)
	CloseServe(ctx context.Context) error
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

// openEngineAs opens the engine of the project named project in dir, an
// absolute path given once (access.OpenAs): setup's work, in the folder it
// entered. A variable so a test stands in a fake engine.
var openEngineAs = func(dir, project string) (stackEngine, error) {
	e, err := access.OpenAs(dir, project, nil)
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
// its lock for command and runs recovery (lockedEngine).
func openLocked(ctx context.Context, command string, out io.Writer) (stackEngine, func(), []access.Receipt, error) {
	e, err := openEngine(".")
	if err != nil {
		return nil, nil, nil, engineFailure(err)
	}
	return lockedEngine(ctx, e, command, out)
}

// lockedEngine takes e's lock for command and runs recovery, printing each
// receipt recovery wrote and, after a hold's receipt, whose start starts
// .env's head alone whether it ran or failed, the sentence naming the
// services of the stack's own that start leaves stopped (unselectedLine). It answers the
// engine, the function that releases the lock, and those receipts.
func lockedEngine(ctx context.Context, e stackEngine, command string, out io.Writer) (stackEngine, func(), []access.Receipt, error) {
	unlock, err := e.Lock(command)
	if err != nil {
		return nil, nil, nil, engineFailure(err)
	}
	receipts, err := e.Resume(ctx)
	for _, r := range receipts {
		fmt.Fprintln(out, "Recovered: "+describeReceipt(r))
		if r.Op != "hold" || r.State != "completed" {
			continue
		}
		if head, err := e.Head(); err == nil {
			u := updater{ctx: ctx, out: out, errOut: io.Discard, engine: e, head: head}
			if line := u.unselectedLine(); line != "" {
				fmt.Fprintln(out, line)
			}
		}
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
	"switch": "The change of how CYFR is reached",
	"join":   "Joining the tailnet",
	"cancel": "Cancelling a tailnet join",
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
	if r.Op == "hold" {
		return describeHold(r)
	}
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

// describeHold is a hold's receipt (access.Engine.Hold) as a person reads
// it: the command that stopped CYFR, and whether the start it owed has
// been paid.
func describeHold(r access.Receipt) string {
	if r.State != "completed" {
		// Unfinished, the receipt records no start: one may have run, as
		// when recovery's start worked and its receipt was not written.
		line := fmt.Sprintf("cyfr %s stopped CYFR, and whether it runs again is not recorded (request %s); `cyfr access status` shows whether it runs.", r.Cause, r.RequestID)
		if ref := r.Refusal(); ref != nil {
			line += " " + ref.Message()
		}
		return line
	}
	line := fmt.Sprintf("CYFR was stopped by an interrupted cyfr %s and has been started again", r.Cause)
	switch r.Outcome {
	case "ok":
	case outcomeStartedLocal:
		line += ", on this machine alone"
	default:
		line = fmt.Sprintf("CYFR was stopped by an interrupted cyfr %s and did not start again", r.Cause)
	}
	line += " (request " + r.RequestID + ")."
	if ref := r.Refusal(); ref != nil {
		line += " " + ref.Message()
	} else if reason := r.Payload["reason"]; reason != "" {
		line += " " + reason + "."
	}
	if r.Outcome == "failed" {
		line += " 'cyfr up' starts it once that is fixed."
	}
	return line
}

// newRequestID mints the request id of one invocation.
func newRequestID() (string, error) {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

// joinRequestID is the request id of the join a switch's request id id
// makes, derived from it.
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

// accessOptions are the inputs of the browser address `cyfr access
// browser` applies.
type accessOptions struct {
	domain, acmeEmail, publish, keyFile, hostname string
	newNode, noOpen                               bool
}

// addAccessFlags adds the flags of the browser address a command applies.
func addAccessFlags(c *cobra.Command) {
	c.Flags().String("domain", "", "The domain CYFR is reached at with domain or proxy: its DNS names this machine, or the machine your proxy runs on")
	c.Flags().String("acme-email", "", "With domain, the email CYFR's certificate authority writes to (optional)")
	c.Flags().String("publish", "", "With proxy, the IPv4 loopback address and port your proxy forwards to (default "+access.DefaultPublish+", or the one .env has)")
	c.Flags().String("tailscale-auth-key-file", "", "A file holding a Tailscale auth key, which joins this machine to the tailnet without the approval link")
	c.Flags().String("hostname", "", "This machine's name on the tailnet (cyfr when not given); certificate names are public")
	c.Flags().Bool("no-open", false, "Do not open a tailnet join's approval link in the default browser")
}

func accessFlags(c *cobra.Command) accessOptions {
	var o accessOptions
	o.domain, _ = c.Flags().GetString("domain")
	o.acmeEmail, _ = c.Flags().GetString("acme-email")
	o.publish, _ = c.Flags().GetString("publish")
	o.keyFile, _ = c.Flags().GetString("tailscale-auth-key-file")
	o.hostname, _ = c.Flags().GetString("hostname")
	o.noOpen, _ = c.Flags().GetBool("no-open")
	if c.Flags().Lookup("new-node") != nil {
		o.newNode, _ = c.Flags().GetBool("new-node")
	}
	return o
}

// checkTailnetOptions refuses a tailnet option given for another kind.
func checkTailnetOptions(browser string, o accessOptions) error {
	for _, option := range []struct {
		name  string
		given bool
	}{{"--tailscale-auth-key-file", o.keyFile != ""}, {"--hostname", o.hostname != ""}, {"--new-node", o.newNode}} {
		if option.given && browser != access.BrowserTailnet {
			return fmt.Errorf("`%s` is for joining a tailnet, and this command chooses `%s`. Nothing was changed. Run it again without `%s`, or run `cyfr access browser tailnet` with it", option.name, browser, option.name)
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
// joined machine; choice's hook is told the link as it is printed. An
// interrupt cancels the waiting join, whose container outlives this
// command otherwise, and answers tailnet_join_cancelled.
func joinTailnet(ctx context.Context, e stackEngine, id string, o accessOptions, key []byte, out io.Writer, choice joinChoice) (string, error) {
	req := access.JoinRequest{
		ID:       id,
		Hostname: o.hostname,
		NewNode:  o.newNode,
		OnAuthURL: func(url string) {
			fmt.Fprintf(out, "To join this machine to your tailnet, open this link and approve the machine:\n  %s\n", hyperlink(out, url))
			if choice.onAuthURL != nil {
				choice.onAuthURL(url)
			}
			fmt.Fprintln(out, "Waiting for the approval (Ctrl-C cancels the join)...")
		},
	}
	if key != nil {
		req.AuthKey = bytes.NewReader(key)
	}
	rec, err := e.Join(ctx, req)
	if ctx.Err() != nil {
		if err == nil && receiptFailure(rec) == nil {
			return "", fmt.Errorf("the join was interrupted after the machine joined your tailnet as %s; how CYFR is reached was not changed, and `cyfr access browser tailnet` takes the machine as it is", rec.Payload["name"])
		}
		if cerr := e.CancelWaitingJoin(context.WithoutCancel(ctx)); cerr != nil {
			return "", fmt.Errorf("the join was interrupted, and cancelling it failed (%v), so its container may wait until its own deadline before it ends; how CYFR is reached was not changed", engineFailure(cerr))
		}
		return "", refusalError{access.Refuse("tailnet_join_cancelled", nil)}
	}
	if err := answerFailure(rec, err); err != nil {
		return "", err
	}
	joinID := rec.Payload["join_id"]
	if joinID == "" {
		return "", fmt.Errorf("the join answered no join id (%s); how CYFR is reached was not changed", describeReceipt(rec))
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
// onAuthURL, when set, is told the approval link.
type joinChoice struct {
	confirm      func(current string) error
	optionsGiven bool
	onAuthURL    func(url string)
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
	if target.Browser != access.BrowserTailnet {
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
	// server's machine (the running tailscale service's, else the latest
	// completed join's), named only where .env agrees with it: .env's head
	// names no machine (any kind but tailnet) or the same node. A tailnet .env
	// naming another node (a restore leaves the machine's state and its
	// last join as they were) or a .env whose head does not read names
	// none, and nor does any refusal but access_unchanged: that one derived
	// .env's own head from the engine's machine, so the machine's name and
	// node id are .env's by the engine's read.
	var known access.Head
	switch {
	case !o.newNode:
	case err == nil:
		switch p.Old.Browser {
		case access.BrowserTailnet:
			if p.Old.NodeID == p.New.NodeID {
				known = p.New
			}
		case access.BrowserNone, access.BrowserDomain, access.BrowserProxy:
			known = p.New
		}
	case r != nil && r.Code == "access_unchanged":
		if h, herr := e.Head(); herr == nil && h.Browser == access.BrowserTailnet {
			known = h
		}
	}
	if choice.confirm != nil {
		if err := choice.confirm(known.Host); err != nil {
			return access.Preview{}, joined{}, err
		}
	}
	joinID, err := joinTailnet(ctx, e, joinRequestID(id), o, key, out, choice)
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
	return fmt.Errorf("This machine is already on your tailnet as `%s`, and %s %s for a new join. Nothing was changed. Run `cyfr access browser tailnet --new-node` with %s to replace its tailnet identity, or run it again without %s", name, joinNames(given), plural(given, "is", "are"), plural(given, "it", "them"), plural(given, "it", "them"))
}

// joinName is the name a join asks the tailnet for.
func joinName(o accessOptions) string {
	if o.hostname != "" {
		return o.hostname
	}
	return "cyfr"
}

// openJoinLink is a join's approval link, once printed, opened in the
// default browser on a machine with a display unless noOpen
// (openOnDisplay); the join waits for the approval either way.
func openJoinLink(noOpen bool, out io.Writer) func(url string) {
	return func(url string) {
		if openOnDisplay(url, noOpen, out) {
			fmt.Fprintln(out, "Opened it in your browser.")
		}
	}
}

// askJoin asks on the terminal whether to make the join a change needs,
// naming what it does: with --new-node, the tailnet identity it removes
// first. The question ends with ctx, before anything joined.
func askJoin(ctx context.Context, in *bufio.Reader, out io.Writer, o accessOptions) func(current string) error {
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
		a, err := ask(ctx, in, out, "Join it? (yes/no)", "no")
		if err != nil {
			return interruption{errQuestionInterrupted}
		}
		if a = strings.ToLower(a); a != "yes" && a != "y" {
			fmt.Fprintln(out, "Nothing changed.")
			return errDeclined
		}
		return nil
	}
}

// errDeclined is a question answered no: what stands is said already, and
// the command ends there, as no failure (exit 0).
var errDeclined = errors.New("declined")

// printPreview prints a change before it is made: who will reach CYFR and
// where (reachedBy), each other setting that changes as before → after
// (changedRows), and, when the address changes and someone may be set up
// at the old one (consequences), what changes with it. A reopen, the
// tailnet head .env holds already with Serve closed, is the home served on
// the tailnet again.
func printPreview(out io.Writer, p access.Preview, consequences bool) {
	if p.Reopen {
		// The head is .env's already: what changes is that the home is
		// served on the tailnet again, once the machine is checked.
		fmt.Fprintf(out, "CYFR answers on this computer only right now. Once the tailnet machine checks out, CYFR will be reached %s.\n", reachedBy(p.New, p.NewWords))
		return
	}
	fmt.Fprintf(out, "CYFR will be reached %s.\n", reachedBy(p.New, p.NewWords))
	for _, line := range changedRows(p) {
		fmt.Fprintln(out, "  "+line)
	}
	if len(p.AddressChanges) > 0 && consequences {
		fmt.Fprintln(out, "The address changes, so:")
		for i, change := range p.AddressChanges {
			fmt.Fprintf(out, "  %d. %s\n", i+1, change)
		}
		fmt.Fprintln(out, access.AccountsUnchanged)
	}
}

// reachedBy is how CYFR at head h, whose words are w, is reached, as
// "CYFR will be reached" and "CYFR is reached" go on: who reaches it and
// at what address, its browser address when it has one and its private
// address when it has none, for domain the ports it opens on this
// machine, and for proxy where the person's proxy forwards to.
func reachedBy(h access.Head, w access.Words) string {
	switch h.Browser {
	case access.BrowserTailnet:
		return "by your devices on Tailscale at " + w.Browser
	case access.BrowserDomain:
		return "by " + w.Who + ", at " + w.Browser + ", through ports " + w.Ports + " on this machine"
	case access.BrowserProxy:
		return "by " + w.Who + ", at " + w.Browser + ", through your proxy, which forwards to " + w.Forward
	}
	return "from this computer at " + w.Private
}

// changedRows are the settings a change makes other than who reaches CYFR
// and its address, which reachedBy says, each as before → after and only
// when it changes: the certificate email, the ports opened on this machine
// unless reachedBy names them, the port of cyfr's listener on this
// computer, and a tailnet machine replaced by a new one, which the address
// shows only when its name changes too.
func changedRows(p access.Preview) []string {
	old, next := p.Old, p.New
	if p.OldWords == (access.Words{}) {
		// .env held no head to compare with.
		return nil
	}
	var lines []string
	if old.NodeID != "" && next.NodeID != "" && old.NodeID != next.NodeID {
		lines = append(lines, "Tailnet machine: "+old.Host+" → a new machine, "+next.Host)
	}
	if p.OldWords.CertificateEmail != p.NewWords.CertificateEmail {
		lines = append(lines, "Certificate email: "+p.OldWords.CertificateEmail+" → "+p.NewWords.CertificateEmail)
	}
	if p.OldWords.Ports != p.NewWords.Ports && next.Browser != access.BrowserDomain {
		lines = append(lines, "Ports opened on this machine: "+p.OldWords.Ports+" → "+p.NewWords.Ports)
	}
	if old.Port != next.Port {
		lines = append(lines, fmt.Sprintf("Port on this computer: %d → %d", old.Port, next.Port))
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
	addAccessFlags(accessBrowserCmd)
	accessBrowserCmd.Flags().Bool("new-node", false, "Replace this machine's tailnet identity before joining, so CYFR can take another name")
	accessBrowserCmd.Flags().Bool("yes", false, "Make the change without asking to confirm it")
	accessCmd.Flags().Bool("resume", false, "Finish an interrupted change under the lock and report what happened")
	accessCmd.AddCommand(accessBrowserCmd, accessStatusCmd)
	rootCmd.AddCommand(accessCmd)
}

var accessCmd = &cobra.Command{
	Use:         "access",
	Annotations: map[string]string{dockerAnnotation: "yes", startsAnnotation: "yes"},
	Short:       "Choose CYFR's browser address, see how it is reached, or finish an interrupted change",
	GroupID:     "server",
	Long: `See and change how the CYFR in the current directory is reached.

'cyfr access browser <none|tailnet|domain|proxy>' chooses its browser address. 'cyfr access status' shows how CYFR is reached and what runs, changing nothing. 'cyfr access --resume' finishes a change an interrupted command left, under the lock, and reports what happened; it is what to run after an interruption.`,
	Example: `  cyfr access browser tailnet
  cyfr access status
  cyfr access --resume`,
	Args: cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		ctx := cmd.Context()
		if ctx == nil {
			ctx = context.Background()
		}
		if resume, _ := cmd.Flags().GetBool("resume"); resume {
			return runAccessResume(ctx, cmd.OutOrStdout())
		}
		return errors.New("name what to do: cyfr access browser none, tailnet, domain or proxy chooses the browser address, and cyfr access status shows the current one")
	},
}

var accessBrowserCmd = &cobra.Command{
	Use:         "browser <none|tailnet|domain|proxy>",
	Annotations: map[string]string{dockerAnnotation: "yes", startsAnnotation: "yes"},
	Short:       "Choose CYFR's browser address: none, your tailnet, a domain, or a domain your own proxy serves",
	Long: `Choose the browser address of the CYFR in the current directory, and every setting that follows from it in .env (CYFR_BROWSER, CYFR_HOST, CYFR_PUBLIC_URL, CYFR_TAILNET_NODE_ID, CADDY_ACME_EMAIL, CYFR_PROXY_PUBLISH).

  none     no browser address: this computer only, at its private address, http://h-<16 letters and digits>.localhost:<CYFR_PORT>, which every CYFR keeps whatever its browser address
  tailnet  your devices on Tailscale, at https://<machine>.<tailnet>.ts.net; the machine joins your tailnet first (the link it prints approves it, and on a machine with a display it opens in the default browser unless --no-open is given; --tailscale-auth-key-file joins it without one)
  domain   anyone on the internet, who still has to sign in, at https://<--domain>, through Caddy on ports 80 and 443
  proxy    a domain your own proxy serves (nginx, a tunnel, a NAS's proxy), at https://<--domain>: CYFR starts no Caddy and publishes its proxy listener on this machine's loopback at --publish (default ` + access.DefaultPublish + `), for your proxy to forward to. Your proxy's forwarded headers are trusted only as .env states: set CYFR_TRUSTED_PROXY_HOPS (1 for your proxy alone) or CYFR_TRUSTED_PROXY_CIDRS there first, or the change is refused

It shows the change first: who will reach CYFR and at what address, with the ports a domain opens, then each other setting that changes, as before → after (the certificate email, the ports opened on this machine, the port on this computer, the builds service). When the address changes it also lists what changes with it for browsers, command lines, OAuth apps, webhook senders and saved addresses, unless no one is set up on CYFR yet; accounts and their passkeys do not change. Confirm it (or pass --yes), and the access containers are stopped, removed and checked stopped, keeping the networks, .env is rewritten, and what was running is started again with the new address; a start that fails puts CYFR back as it was. Once made, it prints CYFR's address on this computer and, with a browser address, that address and its QR code. A domain change then resolves the domain from this machine: it ends on Done only when the domain resolves, and otherwise says that no one reaches CYFR there, and no certificate is issued, until the domain's DNS names this machine. With no terminal to confirm on and no --yes, it shows the change and makes none, and a tailnet change that needs this machine joined first is refused before the join.

When CYFR has a tailnet address and its Tailscale Serve is closed, because the machine was not ready when it started (HTTPS certificates off, say), 'cyfr access browser tailnet' serves it on the tailnet again: it shows that, and once confirmed checks the machine again and opens Serve without stopping anything or rewriting .env.

Exit status 3: the change was made and CYFR started, but on this machine only, because the tailnet machine is not ready to serve it (not the one .env now names, not joined, or HTTPS off); Serve stays closed, and the message says what to do. A refused or failed change exits 1. Answering no to "Join it?" or "Make this change?" says what stands and exits 0.`,
	Example: `  cyfr access browser tailnet
  cyfr access browser domain --domain cyfr.example.com --acme-email ops@example.com
  cyfr access browser proxy --domain cyfr.example.com --publish 127.0.0.1:4001
  cyfr access browser none --yes`,
	Args: cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		ctx := cmd.Context()
		if ctx == nil {
			ctx = context.Background()
		}
		yes, _ := cmd.Flags().GetBool("yes")
		return runAccess(ctx, args[0], accessFlags(cmd), yes, cmd.OutOrStdout())
	},
}

var accessStatusCmd = &cobra.Command{
	Use:   "status",
	Short: "Show how CYFR is reached and what runs, changing nothing",
	Long:  "Show how the CYFR in the current directory is reached, as .env says, the stack's containers, the health of the mode's proxy, a change left unfinished and the last change's outcome. It takes no lock and changes nothing, so it answers while another command runs.",
	Args:  cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		ctx := cmd.Context()
		if ctx == nil {
			ctx = context.Background()
		}
		return runAccessStatus(ctx, cmd.OutOrStdout())
	},
}

// runAccess is `cyfr access browser <kind>`: the preview, the
// confirmation, then the switch under the lock, for tailnet with the join
// first.
func runAccess(ctx context.Context, browser string, o accessOptions, yes bool, out io.Writer) error {
	if !slices.Contains(access.Browsers, browser) {
		return fmt.Errorf("cyfr access browser takes none, tailnet, domain or proxy; %q is none of them", browser)
	}
	if err := checkTailnetOptions(browser, o); err != nil {
		return err
	}
	target := access.Target{Browser: browser, Domain: o.domain, ACMEEmail: o.acmeEmail, Publish: o.publish}
	key, err := readAuthKey(o.keyFile)
	if err != nil {
		return err
	}
	id, err := newRequestID()
	if err != nil {
		return err
	}
	if !yes && !askTerminal() {
		return showUnconfirmed(ctx, target, o, out)
	}
	// The switch starts the stack.
	if err := ensureAppArmor(ctx, out, "cyfr access browser "+browser); err != nil {
		return err
	}

	e, unlock, _, err := openLocked(ctx, "access browser "+browser, out)
	if err != nil {
		return err
	}
	defer unlock()

	in := bufio.NewReader(askInput)
	choice := joinChoice{optionsGiven: o.hostname != "" || o.keyFile != "", onAuthURL: openJoinLink(o.noOpen, out)}
	if !yes {
		choice.confirm = askJoin(ctx, in, out, o)
	}
	p, join, err := previewTarget(ctx, e, target, id, o, key, out, choice)
	if errors.Is(err, errDeclined) {
		return nil
	}
	if err != nil {
		return err
	}
	// Whether anyone can be signed in or connected at the old address: no
	// one can on a CYFR that never booted, nor on one whose log says no
	// one is set up (readSetUp). Read before the switch restarts cyfr;
	// anything else keeps the list.
	fresh, read := neverBooted(), setUpUnknown
	if len(p.AddressChanges) > 0 && !fresh {
		if head, herr := e.Head(); herr == nil {
			read = readSetUp(ctx, e, head)
		}
	}
	printPreview(out, p, !fresh && read != setUpNone)
	if !yes {
		a, err := ask(ctx, in, out, "Make this change? (yes/no)", "no")
		if err != nil {
			// What the join before the question did stands; the
			// change is not made.
			if stands := joinStands(join, p.New.Host); stands != "" {
				return interruption{errors.New("Interrupted. " + stands)}
			}
			return interruption{errQuestionInterrupted}
		}
		if a = strings.ToLower(a); a != "yes" && a != "y" {
			if stands := joinStands(join, p.New.Host); stands != "" {
				fmt.Fprintln(out, stands)
			} else {
				fmt.Fprintln(out, "Nothing changed.")
			}
			return nil
		}
	}

	// The switch runs to its end once it begins: an interrupt then is the
	// journal's to recover, never a half-made change this command walks
	// away from.
	err = answerFailure(e.Switch(context.WithoutCancel(ctx), access.SwitchRequest{
		ID: id, Target: target, JoinID: join.id, OldDigest: p.OldDigest, NewDigest: p.NewDigest,
	}))
	if local := (startedLocally{}); err != nil && !errors.As(err, &local) {
		return err
	}
	if err == nil {
		fmt.Fprintln(out, switchedSentence(ctx, p.New, p.NewWords))
		if p.Reopen {
			printTailscale(ctx, e, out)
		}
		printAddress(out, p.NewWords)
		if p.New.Browser == access.BrowserProxy {
			fmt.Fprintln(out, proxyTrustLimit(p.New.Publish))
		}
	}
	// .env holds the new head now, CYFR started as it says or on this
	// machine only: a CYFR no one is set up on is set up at the new
	// address. One someone is set up on needs nothing more said: the
	// preview listed what changes, and the screen reads the folder each
	// time it starts.
	if len(p.AddressChanges) > 0 {
		values, _ := access.ReadEnvValues(".env")
		switch {
		case fresh:
			fmt.Fprintln(out, upThenSetup(hyperlink(out, setupLink(p.NewWords.Shared(), values))))
		case read == setUpNone:
			setupNext(out, p.New, p.NewWords)
		}
	}
	return err
}

// lookupDomain resolves domain as this machine resolves names; tests stand
// in for it.
var lookupDomain = func(ctx context.Context, domain string) error {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	_, err := net.DefaultResolver.LookupHost(ctx, domain)
	return err
}

// proxyTrustLimit is the limit of a proxy browser address, said when one is
// taken: the publication is on this machine's loopback, where CYFR cannot
// tell the person's proxy from any other program that connects to it.
func proxyTrustLimit(publish string) string {
	return "A stated limit: every program on this machine that can connect to " + publish + " counts as your proxy: CYFR sees Docker's gateway as the peer and cannot tell one local program from another. " +
		"With CYFR_TRUSTED_PROXY_HOPS=0 no forwarded address is believed, and every caller counts as one address. " +
		"With one hop or more, or a CYFR_TRUSTED_PROXY_CIDRS that covers Docker's gateway, any such program chooses the client address CYFR uses for its per-address limits and for an API key's address allowlist. " +
		"Credentials are still required either way, and the scheme is the listener's, not a header's."
}

// printAddress prints CYFR's addresses after a change: its private
// address, which this computer opens, and its browser address when it has
// one, with its QR code for a phone to open it from; an address no QR code
// holds is printed alone.
func printAddress(out io.Writer, w access.Words) {
	fmt.Fprintln(out, "CYFR's address on this computer: "+hyperlink(out, w.Private))
	if w.Browser == "" {
		return
	}
	fmt.Fprintln(out, "CYFR's browser address: "+hyperlink(out, w.Browser))
	if code, err := setup.QRText(w.Browser); err == nil {
		fmt.Fprint(out, code)
	}
}

// switchedSentence is the sentence a change that took ends on: Done, with
// how CYFR is reached at head, once a domain Caddy serves resolves. A
// domain the resolver answers does not exist is said instead, since no one
// reaches CYFR there and no certificate can be issued until its DNS names
// this machine; a lookup that times out or fails otherwise proves neither,
// and is said as a check this machine could not make. A proxy's domain
// names the person's proxy, which this machine cannot check.
func switchedSentence(ctx context.Context, head access.Head, w access.Words) string {
	if head.Browser == access.BrowserDomain {
		err := lookupDomain(ctx, head.Host)
		var dns *net.DNSError
		switch {
		case errors.As(err, &dns) && dns.IsNotFound:
			return fmt.Sprintf("CYFR is set to be reached %s, but %s does not resolve from this machine (%v). No one reaches CYFR there, and no certificate is issued, until the domain's DNS names this machine's public address; CYFR takes its certificate once it does, and cyfr access status shows it.", reachedBy(head, w), head.Host, err)
		case err != nil:
			return fmt.Sprintf("CYFR is set to be reached %s, but this machine could not check whether %s resolves (%v). CYFR takes its certificate once the domain's DNS names this machine's public address; cyfr access status shows whether it has one.", reachedBy(head, w), head.Host, err)
		}
	}
	return "Done. CYFR is reached " + reachedBy(head, w) + "."
}

// joinStands is what a join made before a change that was not made leaves
// standing, as the sentence that says it and the next step; "" when the
// change needed no join.
func joinStands(join joined, host string) string {
	switch {
	case join.removed != "":
		return fmt.Sprintf("This machine is on your tailnet as %s now, and its old tailnet identity %s was removed: remove %s in the Tailscale admin console too. Nothing else changed; run cyfr access browser tailnet again when you want CYFR reached there.", host, join.removed, join.removed)
	case join.id != "":
		return fmt.Sprintf("Nothing changed. This machine stays on your tailnet as %s; run cyfr access browser tailnet again when you want CYFR reached there.", host)
	}
	return ""
}

// printTailscale prints the tailnet machine as the engine sees it now
// (Status): whether it is connected as the machine .env names, its HTTPS
// certificates and whether Serve is open.
func printTailscale(ctx context.Context, e stackEngine, out io.Writer) {
	st, err := e.Status(ctx)
	if err != nil {
		return
	}
	lines := st.Health
	if st.Unobserved != nil {
		lines = []string{"Docker did not answer: " + st.Unobserved.Error()}
	}
	if len(lines) == 0 {
		return
	}
	fmt.Fprintln(out, "Tailscale now:")
	for _, line := range lines {
		fmt.Fprintln(out, "  "+line)
	}
}

// showUnconfirmed is `cyfr access browser <kind>` with no terminal to confirm on and
// no --yes: the change shown when its preview needs no join, read without
// the lock, and refused either way, nothing changed and no input read. A
// preview that needs the machine joined is refused before the join, which
// would change the tailnet.
func showUnconfirmed(ctx context.Context, target access.Target, o accessOptions, out io.Writer) error {
	const again = "Run it again with --yes to make the change, or at a terminal"
	joinFirst := errors.New("Nothing changed: this machine must join your tailnet before the change can be shown, and there is no terminal to confirm the join on. " + again)
	if target.Browser == access.BrowserTailnet && o.newNode {
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
	if target.Browser == access.BrowserTailnet && (o.hostname != "" || o.keyFile != "") {
		return alreadyJoined(p.New.Host, o)
	}
	// This path takes no lock, and cyfr's log is read only under it
	// (readSetUp), so whether anyone is set up cannot be told here: the
	// consequence list stays, as it does whenever the read cannot tell,
	// unless CYFR never booted in this directory.
	printPreview(out, p, !neverBooted())
	return errors.New("Nothing changed: there is no terminal to confirm the change on. " + again)
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
		fmt.Fprintln(out, "Nothing was left unfinished.")
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
		fmt.Fprintln(out, ".env says no coherent way CYFR is reached: "+engineFailure(st.HeadErr).Error())
	} else {
		fmt.Fprintln(out, "CYFR is reached as .env says:")
		printWords(out, st.Words)
	}
	switch {
	case st.Unobserved != nil:
		fmt.Fprintln(out, "Docker did not answer: "+st.Unobserved.Error())
	case len(st.Containers) == 0:
		fmt.Fprintln(out, "Nothing of the stack runs.")
	default:
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
