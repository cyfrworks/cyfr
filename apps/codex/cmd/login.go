// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"github.com/cyfr/codex/internal/ops"
	"io/fs"
	"net/url"
	"os"
	"runtime"
	"strings"
	"sync"
	"time"

	"github.com/cyfr/codex/internal/access"
	"github.com/cyfr/codex/internal/config"
	"github.com/cyfr/codex/internal/mcp"
	"github.com/cyfr/codex/internal/setup"
	"github.com/cyfr/codex/internal/shell"
	"github.com/spf13/cobra"
	"golang.org/x/term"
)

var (
	flagLoginSetup      bool
	flagLoginJoin       bool
	flagLoginInvitation string
	flagLoginName       string
	flagLoginPIN        bool
)

func init() {
	loginCmd.Flags().BoolVar(&flagLoginSetup, "setup", false,
		"Set up this CYFR's first person at this terminal, with this command line as their device, with CYFR_SETUP_TOKEN from .env in this directory")
	loginCmd.Flags().BoolVar(&flagLoginJoin, "join", false,
		"Join this CYFR as a new person with this command line as your device, by its open admission or --invitation")
	loginCmd.Flags().StringVar(&flagLoginInvitation, "invitation", "",
		"With --join: the code of the invitation that admits you")
	loginCmd.Flags().StringVar(&flagLoginName, "name", "",
		"With --setup or --join: your name, yours for life (asked for when not given)")
	loginCmd.Flags().BoolVar(&flagLoginPIN, "pin", false,
		"Keep this command line's key under a six-digit PIN that CYFR counts, in place of its passphrase, or under a new PIN (a machine without a chip, at a CYFR on another machine)")

	rootCmd.AddCommand(loginCmd)
	rootCmd.AddCommand(logoutCmd)
	rootCmd.AddCommand(whoamiCmd)

	config.SignedOut = signedOut
}

// signedOut says, once, that the sign-in an earlier command line saved
// for contexts was deleted: it proved no device, and cyfr login now makes
// this command line one.
func signedOut(contexts []string) {
	fmt.Fprintf(os.Stderr, "The sign-in this command line saved for %s was deleted: cyfr login now makes this command line a device of yours, unlocked in a shell of its own. Run cyfr login.\n",
		strings.Join(contexts, ", "))
}

var loginCmd = &cobra.Command{
	Use:     "login",
	Short:   "Unlock this command line, a device of yours, in a shell of its own",
	GroupID: "identity",
	Long: `Unlock this command line with its own key and work in a shell that holds
your session. The command line is a device of yours, as a phone or this
CYFR's screen is: it holds a key that it unlocks here, and CYFR checks the
key's signature, never your PIN.

The key is kept by this machine's TPM chip under a six-digit PIN when the
chip can protect one (eight wrong tries, then one every ten minutes), and
otherwise under a six-word passphrase that cyfr login draws for you and
shows once. A short PIN is never accepted without the chip.

The first time, at a CYFR where you already have a device, cyfr login makes
the key and shows a QR code and a code. Scan the QR code with your phone,
or open the address it prints on a device signed in to CYFR and type the
code there. That device shows what is added and asks you to unlock it
again; then it shows a link. Paste the link here, or type its code: the
pairing completes with this key alone.

Where your identity is kept by your own CYFR and not the one you pair
with, the pairing asks for your CYFR's address: your CYFR certifies this
command line for the other one, here in the terminal. This command line must
be a device of yours at your CYFR already (cyfr login --url <your CYFR>
first): its key there is unlocked with its PIN or passphrase, and the
certification is confirmed like any change, here or on another device of
yours there. The same is asked again when your CYFR's keys change.

Unlocked, cyfr login starts your shell ($SHELL) with the session in its
environment. Every cyfr command run in it acts as you, and the session
lives only while this command line keeps reporting to CYFR: exiting the
shell, closing the terminal, cyfr logout or a lost connection ends it.
cyfr open in that shell opens CYFR in your browser through this unlock. A
change that needs a fresh confirmation asks your PIN or passphrase again
in the terminal, over what CYFR shows of the change.

A machine without a chip pairs under its passphrase. Once paired, cyfr
login --pin keeps the key under a six-digit PIN instead, after you confirm
the change: every unlock then asks CYFR to count the try (each wrong one
makes the next wait longer, up to an hour), so a copy of this machine's
disk cannot guess the PIN offline, and the first unlock after a reboot
needs CYFR. A copy of both this disk and CYFR's data can still be guessed,
and restoring CYFR from a backup brings back an older count. cyfr login
--pin again sets a new PIN. Where CYFR runs on this same machine, its data
and the key share one disk and a count protects nothing, so --pin is
refused: a self-contained box keeps its key under its chip's PIN or a
passphrase.

--setup makes any CYFR's first person at this terminal, with this command
line as their device, from the directory cyfr init set up, which holds
CYFR_SETUP_TOKEN in .env: the terminal's way, beside the setup link's
passkey in a browser, and a headless CYFR's (CYFR_HEADLESS=on) only way,
since it serves no setup page. --join makes you a new person at a CYFR
whose admission is open to you, or with --invitation, by an invitation's code.
Each shows your recovery code, as a QR code and as text, until you press
Enter to say you saved it.

Unattended work, a script or CI, uses an API key (--token or CYFR_TOKEN),
not cyfr login.`,
	Example: `  cyfr login
  cyfr login --context work
  cyfr login --setup --name mira
  cyfr login --join --invitation 7Kq2-pX9a-... --name mira
  cyfr login --pin`,
	Args: cobra.NoArgs,
	RunE: runLogin,
}

// runLogin unlocks this command line's device for the home the command
// names (pairing it, or setting up or joining as a new person, first),
// opens a session of its own by the unlock's ticket and holds it in a
// shell (holdShell).
func runLogin(cmd *cobra.Command, _ []string) error {
	joining := flagLoginJoin || cmd.Flags().Changed("invitation")
	if flagLoginPIN {
		// Refused before anything is asked or made: a PIN the home counts
		// protects nothing where the home is this machine.
		address, err := loginAddress()
		if err != nil {
			return err
		}
		if homeHere(address) {
			return errors.New(shell.PINHereSentence("command line"))
		}
	}
	switch {
	case flagLoginSetup && joining:
		return errors.New("--setup makes this CYFR's first person and --join a new person at a CYFR that has one: use one of them.")
	case cmd.Flags().Changed("name") && !flagLoginSetup && !joining:
		return errors.New("--name names the person --setup or --join makes: use it with one of them.")
	case runtime.GOOS == "windows":
		return errors.New("cyfr login holds a device on Linux and macOS. On Windows, use an API key (--token or CYFR_TOKEN).")
	case os.Getenv(sessionHomeEnv) != "":
		return errors.New("This terminal is unlocked by cyfr login already: exit its shell first.")
	case !term.IsTerminal(int(os.Stdin.Fd())) || !term.IsTerminal(int(os.Stdout.Fd())):
		return errors.New("cyfr login unlocks this command line on a terminal. Unattended work uses an API key (--token or CYFR_TOKEN).")
	}

	address, err := loginAddress()
	if err != nil {
		return err
	}
	o := deviceOptions{address: address, invitation: strings.TrimSpace(flagLoginInvitation)}
	// pin.enroll goes through the session this unlock opens, set below
	// before SetPIN asks for it.
	var session string
	console := newConsole(os.Stdout)
	if flagLoginPIN {
		o.enrollPIN = func(ctx context.Context) (string, error) { return enrollPIN(ctx, address, session, console) }
	}
	o.certify = certifyAtHome(console)
	if flagLoginSetup {
		if o.setupToken, err = setupTokenHere(); err != nil {
			return err
		}
	}
	locked := make(chan struct{})
	var once sync.Once
	o.locked = func() { once.Do(func() { close(locked) }) }
	sh, err := openDevice(o)
	if err != nil {
		return err
	}

	mode := "pair"
	switch {
	case flagLoginSetup:
		mode = "setup"
	case joining:
		mode = "join"
	}
	d := &loginDriver{sh: sh, c: console, mode: mode, name: typedName(flagLoginName),
		invitation: o.invitation, home: address}
	if err := d.run(cmd.Context()); err != nil {
		return err
	}
	session, err = sh.Session(cmd.Context())
	if err != nil {
		sh.Lock("")
		return fmt.Errorf("Unlocked, but CYFR opened no session for this command line, so it locked again: %s", strings.TrimSuffix(shellSentence(err), "."))
	}
	if flagLoginPIN {
		if err := d.setPIN(cmd.Context()); err != nil {
			sh.Lock("")
			return err
		}
	}
	var pages *shell.Server
	if s, ok := sh.(*sessionDevice); ok {
		pages = &shell.Server{Shell: s.Shell}
	}
	return holdShell(sh, pages, address, session, locked)
}

// shellSentence is a failure of the shell's as the person reads it.
func shellSentence(err error) string {
	var home *shell.HomeError
	if errors.As(err, &home) && home.Code == "ticket_refused" {
		return "CYFR did not take this unlock's ticket. Run cyfr login again."
	}
	return err.Error()
}

// loginAddress is the home cyfr login unlocks for: --url, else the
// --context's address, else the current context's.
func loginAddress() (string, error) {
	cfg, err := config.Load()
	if err != nil {
		return "", fmt.Errorf("Could not read the command line's config: %w", err)
	}
	address := serverURL(cfg)
	u, err := url.Parse(address)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
		return "", fmt.Errorf("%q is not CYFR's address: give its https:// or http:// address", address)
	}
	return strings.TrimRight(address, "/"), nil
}

// loginDriver walks this command line's device through its pages, as
// the box's screen walks the same shell through its own: a key made and
// enrolled or paired, unlocked, the recovery code saved and the name
// taken, until it is unlocked.
type loginDriver struct {
	sh         device
	c          *console
	mode       string // pair, setup or join
	name       string
	invitation string
	home       string
	// held is the PIN or passphrase a pairing chose, kept from the key's
	// making to its pairing's completion, then erased.
	held []byte
}

// run acts on each page until the device is unlocked. An action that
// leaves the page as it was, with a sentence, ends the run with that
// sentence, which says how to go on; nothing is retried by itself.
func (d *loginDriver) run(ctx context.Context) error {
	defer func() { clear(d.held) }()
	for {
		v := d.sh.View()
		d.sh.Begin()
		var err error
		switch v.Page {
		case shell.PageSetup, shell.PageRestore:
			err = d.begin(ctx, v)
		case shell.PageFinish:
			err = d.finish(ctx, v)
		case shell.PageLocked:
			err = d.unlock(ctx, v)
		case shell.PageRecovery:
			err = d.saved(ctx, v)
		case shell.PageName:
			err = d.rename(ctx)
		case shell.PageUnlocked:
			return nil
		default:
			d.sh.Lock("")
			return errors.New("This command line is in a state cyfr login does not know. Run cyfr login again.")
		}
		if err != nil {
			d.sh.Lock("")
			return err
		}
		after := d.sh.View()
		if after.Page == shell.PageName && after.NameWaits {
			// The person is made; cyfr.run takes their name, and shows
			// their recovery code after it, at the next run.
			d.sh.Lock("")
			return fmt.Errorf("cyfr.run did not answer. Run %s again to finish.", d.again())
		}
		if after.Notice == "" {
			continue
		}
		if after.Page == v.Page && after.Passphrase == v.Passphrase && after.Name == v.Name {
			d.sh.Lock("")
			return errors.New(after.Notice)
		}
		fmt.Fprintln(d.c.out, after.Notice)
	}
}

// again is the command that finishes what this run began.
func (d *loginDriver) again() string {
	switch {
	case d.mode == "setup":
		return "cyfr login --setup"
	case d.mode == "join" && d.invitation != "":
		return "cyfr login --join --invitation CODE"
	case d.mode == "join":
		return "cyfr login --join"
	}
	return "cyfr login"
}

// begin makes this device's key: for a pairing, before its code is shown;
// for setup or a new person, enrolled under the admission at once.
func (d *loginDriver) begin(ctx context.Context, v shell.View) error {
	var name string
	if d.mode != "pair" {
		var err error
		if name, err = d.askName(ctx); err != nil {
			return err
		}
	}
	secret, again, err := d.newSecret(ctx, v)
	if err != nil {
		return err
	}
	switch d.mode {
	case "setup":
		d.sh.Setup(ctx, name, secret, again)
	case "join":
		d.sh.Join(ctx, d.invitation, name, secret, again)
	default:
		d.held = bytes.Clone(secret)
		d.sh.Prepare(secret, again)
		clear(secret)
		if d.sh.View().Page != shell.PageFinish {
			clear(d.held)
			d.held = nil
		}
	}
	return nil
}

// newSecret asks for the PIN, twice, where the chip keeps it, or shows the
// passphrase drawn for this device and asks for it twice.
func (d *loginDriver) newSecret(ctx context.Context, v shell.View) ([]byte, []byte, error) {
	out := d.c.out
	if v.Chip && v.Passphrase == "" {
		fmt.Fprintln(out, "Choose a six-digit PIN for this command line. This machine's chip keeps it: eight wrong tries, then one every ten minutes.")
		return d.twice(ctx, "PIN: ", "The same PIN again: ")
	}
	fmt.Fprintf(out, "This machine has no chip to keep a short PIN safe, so this command line uses this passphrase. Write it down:\n\n  %s\n\n", v.Passphrase)
	return d.twice(ctx, "The passphrase: ", "The passphrase again: ")
}

func (d *loginDriver) twice(ctx context.Context, first, second string) ([]byte, []byte, error) {
	secret, err := d.c.secret(ctx, first)
	if err != nil {
		return nil, nil, err
	}
	again, err := d.c.secret(ctx, second)
	if err != nil {
		clear(secret)
		return nil, nil, err
	}
	return secret, again, nil
}

// askSecret asks for this device's PIN or passphrase, once.
func (d *loginDriver) askSecret(ctx context.Context, v shell.View, why string) ([]byte, error) {
	if v.Kind == "chip" || v.PIN {
		return d.c.secret(ctx, why+" PIN: ")
	}
	return d.c.secret(ctx, why+" passphrase: ")
}

// finish completes an enrollment or a pairing whose key is made: a
// pairing shows its code and takes the link a device of the person
// answered; an enrollment proves the same key again, by resume first.
func (d *loginDriver) finish(ctx context.Context, v shell.View) error {
	if v.Admission != "pair" {
		if d.mode == "pair" {
			return fmt.Errorf("This command line began to %s, and CYFR's answer did not arrive. Run cyfr login --%s again to finish.",
				map[string]string{"setup": "set up CYFR", "invitation": "join CYFR", "open": "join CYFR"}[v.Admission],
				map[string]string{"setup": "setup", "invitation": "join", "open": "join"}[v.Admission])
		}
		fmt.Fprintln(d.c.out, "CYFR's answer did not arrive last time. This finishes setting up.")
		name, err := d.askName(ctx)
		if err != nil {
			return err
		}
		secret, err := d.askSecret(ctx, v, "This command line's")
		if err != nil {
			return err
		}
		d.sh.Finish(ctx, name, d.invitation, secret)
		return nil
	}
	if d.mode != "pair" {
		return errors.New("This command line made its key to pair with a person here. Run cyfr login to finish pairing it.")
	}
	qr, err := setup.QRText(shell.ApproveURL(d.home, v.Digest))
	if err != nil {
		return err
	}
	out := d.c.out
	fmt.Fprintf(out, "\nThis command line is not a device of yours at %s yet. Approve it on a device you already use:\n\n%s\n", d.home, qr)
	fmt.Fprintf(out, "Scan the code with your phone, or open %s/devices/add there and type:\n\n  %s\n\n", d.home, shell.KeyCode(v.Digest))
	fmt.Fprintln(out, "Once you confirm the addition there, CYFR shows a link. Paste it here, or type its code.")
	link, err := d.c.line(ctx, "Link or code: ")
	if err != nil {
		return err
	}
	secret := d.held
	d.held = nil
	if secret == nil {
		if secret, err = d.askSecret(ctx, v, "This command line's"); err != nil {
			return err
		}
	}
	d.sh.Pair(ctx, string(link), secret)
	return nil
}

// setPIN asks the new PIN twice and keeps this unlocked command line's key
// under it (SetPIN), once the change is confirmed through the session.
func (d *loginDriver) setPIN(ctx context.Context) error {
	fmt.Fprintln(d.c.out, "Choose a six-digit PIN for this command line. CYFR counts every try: each wrong one makes the next wait longer.")
	pin, again, err := d.twice(ctx, "New PIN: ", "The same PIN again: ")
	if err != nil {
		return err
	}
	d.sh.SetPIN(ctx, pin, again)
	notice := d.sh.View().Notice
	if !strings.Contains(notice, "now kept under your six-digit PIN") {
		return errors.New(notice)
	}
	fmt.Fprintln(d.c.out, notice)
	return nil
}

// enrollPIN is pin.enroll through session: answered confirmation_required,
// the change is confirmed in this terminal on this device (its key opened
// afresh by its passphrase or current PIN) or on another device, and the
// call repeats; the home answers the new evaluator's identifier.
func enrollPIN(ctx context.Context, address, session string, c *console) (string, error) {
	client := mcp.NewClient(address)
	client.SessionID = session
	client.Confirm = (&confirmationWait{
		out:         c.out,
		interactive: func() bool { return true },
		lines:       c.lines,
		now:         time.Now,
		address:     address,
		device:      func(address string) deviceConfirmer { return confirmOnDeviceBy(address, session) },
	}).wait
	answer, err := client.CallTool(ctx, pinTool, map[string]any{"action": pinEnrollAction})
	if err != nil {
		return "", err
	}
	evaluator, _ := answer["evaluator"].(string)
	if evaluator == "" {
		return "", errors.New("CYFR answered no evaluator")
	}
	return evaluator, nil
}

// The PIN enrollment's operation, pin.enroll.
const (
	pinTool         = ops.Pin
	pinEnrollAction = ops.PinEnroll
)

// unlock opens this command line with its secret. A home that refused its
// standing, or does not take its PIN (a restore from a backup suspended
// it, or it was removed), offers the recovery code here, as the screen's
// lock page does: the code re-enables this command line's client (and its
// PIN's evaluator) before the secret, asked again, opens the key. An empty
// code leaves it locked with the home's sentence.
func (d *loginDriver) unlock(ctx context.Context, v shell.View) error {
	secret, err := d.askSecret(ctx, v, "Unlock this command line with its")
	if err != nil {
		return err
	}
	d.sh.Unlock(ctx, secret)
	after := d.sh.View()
	if after.Page != shell.PageLocked || !after.Kit {
		return nil
	}
	fmt.Fprintln(d.c.out, after.Notice)
	code, err := d.c.secret(ctx, "Your recovery code, to bring this command line back (Enter to leave it): ")
	if err != nil {
		return err
	}
	defer clear(code)
	if len(bytes.TrimSpace(code)) == 0 {
		return errors.New(after.Notice)
	}
	if secret, err = d.askSecret(ctx, after, "Then this command line's"); err != nil {
		return err
	}
	d.sh.Reenable(ctx, string(code), secret)
	return nil
}

// saved shows the recovery code, as a QR code to scan and as text, until
// the person presses Enter to say they saved it.
func (d *loginDriver) saved(ctx context.Context, v shell.View) error {
	out := d.c.out
	fmt.Fprintf(out, "\nYour name is @%s.\nYour recovery code:\n\n", v.Recovery.Name)
	if qr, err := setup.QRText(v.Recovery.Code); err == nil {
		fmt.Fprintln(out, qr)
	}
	fmt.Fprintf(out, "  %s\n\n", v.Recovery.Code)
	fmt.Fprintln(out, "If CYFR is ever lost, this is the one thing that brings you back. Save it off this machine: scan it, or put it in your password manager.")
	if _, err := d.c.line(ctx, "Press Enter once you saved it. "); err != nil {
		return err
	}
	d.sh.Saved(ctx)
	return nil
}

func (d *loginDriver) rename(ctx context.Context) error {
	d.name = ""
	name, err := d.askName(ctx)
	if err != nil {
		return err
	}
	d.sh.Rename(ctx, name)
	return nil
}

// askName is the name given with --name, else the one typed.
func (d *loginDriver) askName(ctx context.Context) (string, error) {
	for d.name == "" {
		line, err := d.c.line(ctx, "Your name, yours for life: @")
		if err != nil {
			return "", err
		}
		d.name = typedName(string(line))
	}
	return d.name, nil
}

// typedName is a name as typed, without the @ that is written before it
// and the spaces around it; CYFR checks its spelling.
func typedName(typed string) string {
	return strings.TrimPrefix(strings.TrimSpace(typed), "@")
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

var logoutCmd = &cobra.Command{
	Use:     "logout",
	Short:   "Lock this command line",
	GroupID: "identity",
	Long: `Lock this command line: the shell cyfr login started ends, and with it
the session it held at CYFR and any browser session cyfr open opened
through it. Run it in that shell; exiting the shell locks it the same way.`,
	Example: "  cyfr logout",
	Args:    cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		pid := os.Getenv(shellPIDEnv)
		if pid == "" || os.Getenv(sessionHomeEnv) == "" {
			return errors.New("This terminal holds no session of cyfr login, so there is nothing to lock.")
		}
		if err := endShell(pid); err != nil {
			return fmt.Errorf("Could not lock this command line (%v): exit this shell to lock it.", err)
		}
		fmt.Println("Locking.")
		return nil
	},
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
