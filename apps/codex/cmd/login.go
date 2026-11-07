// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io/fs"
	"net/url"
	"os"
	"runtime"
	"strings"
	"sync"
	"time"

	"github.com/cyfr/codex/internal/access"
	"github.com/cyfr/codex/internal/config"
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
your session. The command line is a device of your account, as a phone or a
CYFR box's screen is: it holds one key, for every CYFR you sign in to, that
it unlocks here, and CYFR checks the key's signature, never your PIN.

The key is kept by this machine's TPM chip under a six-digit PIN when the
chip can protect one (eight wrong tries, then one every ten minutes), and
otherwise under a six-word passphrase that cyfr login draws for you and
shows once. A short PIN is never accepted without the chip.

The first time, cyfr login makes the key and shows its code, a QR code and
a command. Scan the QR code with your phone, or open its address on a
device where you use your passkey, check that it shows the same code and
add this command line to your account there; or run the command it shows
on a terminal of yours that is unlocked. Then type your name: cyfr login
waits until your account lists the key. The first unlock at each CYFR
introduces this command line to it. Each later run reads your account
first: once the key is removed from it, cyfr login says so and shows the
same key's code again, to be added the same way.

Unlocked, cyfr login starts your shell ($SHELL) with the session in its
environment. Every cyfr command run in it acts as you, and the session
lives only while this command line keeps reporting to CYFR: exiting the
shell, closing the terminal, cyfr logout or a lost connection ends it.
cyfr open in that shell opens CYFR in your browser through this unlock. A
change that needs a fresh confirmation asks your PIN or passphrase again
in the terminal, over what CYFR shows of the change.

--setup makes you this CYFR's first person at this terminal, from the
directory cyfr init set up, which holds CYFR_SETUP_TOKEN in .env: the
terminal's way, beside the setup link in a browser, and a headless CYFR's
(CYFR_HEADLESS=on) only way, since it serves no setup page. --join comes
in as a new person at a CYFR whose admission is open to you, or with
--invitation, by an invitation's code. Without an account yet, each makes
your account here, with this command line its first device: it shows your
recovery code, as a QR code and as text, until you press Enter to say you
saved it, and only then sends anything.

Unattended work, a script or CI, uses an API key (--token or CYFR_TOKEN),
not cyfr login.`,
	Example: `  cyfr login
  cyfr login --context work
  cyfr login --setup --name mira
  cyfr login --join --invitation 7Kq2-pX9a-... --name mira`,
	Args: cobra.NoArgs,
	RunE: runLogin,
}

// runLogin unlocks this command line's device for the CYFR the command
// names (making its key and adding it to an account, or making the
// account, first), opens a session of its own by the unlock's ticket and
// holds it in a shell (holdShell).
func runLogin(cmd *cobra.Command, _ []string) error {
	joining := flagLoginJoin || cmd.Flags().Changed("invitation")
	switch {
	case flagLoginSetup && joining:
		return errors.New("--setup makes this CYFR's first person and --join a new person at a CYFR that has one: use one of them.")
	case cmd.Flags().Changed("name") && !flagLoginSetup && !joining:
		return errors.New("--name names the account --setup or --join makes: use it with one of them.")
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
	console := newConsole(os.Stdout)
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

	mode := "login"
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
	session, err := sh.Session(cmd.Context())
	if err != nil {
		sh.Lock("")
		return fmt.Errorf("Unlocked, but CYFR opened no session for this command line, so it locked again: %s", strings.TrimSuffix(shellSentence(err), "."))
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
// added to an account, or an account made with it, then unlocked.
type loginDriver struct {
	sh         device
	c          *console
	mode       string // login, setup or join
	name       string
	invitation string
	home       string
	// held is the PIN or passphrase chosen for a key made in this run,
	// kept from its making to its first unlock, then erased.
	held []byte
}

// enrollWait is how long cyfr login waits for the account's log to list
// this command line's key.
var enrollWait = 10 * time.Minute

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
		case shell.PageSetup:
			err = d.setup(ctx, v)
		case shell.PageEnroll:
			err = d.enroll(ctx, v)
		case shell.PageRecovery:
			err = d.saved(ctx, v)
		case shell.PageAccount:
			err = d.finish(ctx)
		case shell.PageName:
			err = d.rename(ctx, v)
		case shell.PageResume:
			err = d.resume(ctx, v)
		case shell.PageLocked:
			err = d.unlock(ctx, v)
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
		if after.Notice == "" {
			continue
		}
		if after.Page == v.Page && after.Passphrase == v.Passphrase && after.Name == v.Name {
			d.sh.Lock("")
			return fmt.Errorf("%s Run %s to go on.", after.Notice, d.again())
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

// making is whether this run makes an account when the key has none.
func (d *loginDriver) making() bool { return d.mode != "login" }

// setup makes this device's key: for a new account, with the account
// itself; otherwise alone, its PIN or passphrase kept for the first
// unlock once an account lists it.
func (d *loginDriver) setup(ctx context.Context, v shell.View) error {
	var name, accepted string
	if d.making() {
		var err error
		if accepted, err = d.accept(ctx); err != nil {
			return err
		}
		if name, err = d.askName(ctx, "Your name, yours for life: @"); err != nil {
			return err
		}
	}
	secret, again, err := d.newSecret(ctx, v)
	if err != nil {
		return err
	}
	if d.making() {
		d.sh.Setup(ctx, name, accepted, secret, again)
		return nil
	}
	d.held = bytes.Clone(secret)
	d.sh.Make(secret, again)
	if d.sh.View().Page == shell.PageSetup {
		clear(d.held)
		d.held = nil
	}
	return nil
}

// accept asks the person to accept the account service's terms, where it
// names any, and answers the version accepted.
func (d *loginDriver) accept(ctx context.Context) (string, error) {
	policy, err := d.sh.Terms(ctx)
	if err != nil {
		return "", fmt.Errorf("The account service could not be reached (%v). Nothing was made; run %s again.", err, d.again())
	}
	if policy == nil {
		return "", nil
	}
	fmt.Fprintf(d.c.out, "Making your account accepts the terms at %s\n", policy.URL)
	answer, err := d.c.line(ctx, "Accept them? (yes/no) ")
	if err != nil {
		return "", err
	}
	if a := strings.ToLower(strings.TrimSpace(string(answer))); a != "yes" && a != "y" {
		return "", errors.New("Nothing was made: your account needs the terms accepted.")
	}
	return policy.Version, nil
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
	if v.Kind == "chip" {
		return d.c.secret(ctx, why+" PIN: ")
	}
	return d.c.secret(ctx, why+" passphrase: ")
}

// enroll adds this device's key to the person's account: the account
// made here with it, for --setup and --join; otherwise its code, the QR
// code of the account page that adds it and the command that does, then
// the name, and a wait until the account lists it.
func (d *loginDriver) enroll(ctx context.Context, v shell.View) error {
	if d.making() {
		accepted, err := d.accept(ctx)
		if err != nil {
			return err
		}
		name, err := d.askName(ctx, "Your name, yours for life: @")
		if err != nil {
			return err
		}
		d.sh.Create(ctx, name, accepted)
		return nil
	}
	out := d.c.out
	fmt.Fprintf(out, "\nThis command line is not a device of your account. Its code is %s.\n\n", v.Code)
	if qr, err := setup.QRText(v.AddURL); err == nil {
		fmt.Fprintln(out, qr)
	}
	fmt.Fprintf(out, "Scan the code with your phone, or open this address on a device where you use your passkey, and check that it shows %s:\n\n  %s\n\n", v.Code, v.AddURL)
	fmt.Fprintf(out, "Or run this on a terminal of yours that is unlocked:\n\n  cyfr device approve %s\n\n", v.Key)
	name, err := d.askName(ctx, "Your name: @")
	if err != nil {
		return err
	}
	fmt.Fprintf(out, "Waiting until your account lists this command line (up to %d minutes; Ctrl+C stops).\n", int(enrollWait.Minutes()))
	d.sh.Enroll(ctx, name, enrollWait)
	return nil
}

// unlock opens this command line with its secret: the one chosen in this
// run, or the one asked once the account's log, read first, still lists
// the key. A log that no longer lists it shows the code again (enroll),
// and nothing is asked.
func (d *loginDriver) unlock(ctx context.Context, v shell.View) error {
	secret := d.held
	d.held = nil
	if secret == nil {
		d.sh.CheckListed(ctx)
		if after := d.sh.View(); after.Page != shell.PageLocked || after.Notice != "" {
			return nil
		}
		var err error
		if secret, err = d.askSecret(ctx, v, "Unlock this command line with its"); err != nil {
			return err
		}
	}
	d.sh.Unlock(ctx, secret)
	return nil
}

// saved shows the recovery code, as a QR code to scan and as text, until
// the person presses Enter to say they saved it; nothing is sent before.
func (d *loginDriver) saved(ctx context.Context, v shell.View) error {
	out := d.c.out
	fmt.Fprintf(out, "\nYour account is @%s. Your recovery code:\n\n", v.Name)
	if qr, err := setup.QRText(v.RecoveryCode); err == nil {
		fmt.Fprintln(out, qr)
	}
	fmt.Fprintf(out, "  %s\n\n", v.RecoveryCode)
	fmt.Fprintln(out, "If you ever lose your devices, this is the one thing that brings your account back. Save it off this machine: scan it, or put it in your password manager. Nothing is sent until you do.")
	if _, err := d.c.line(ctx, "Press Enter once you saved it. "); err != nil {
		return err
	}
	d.sh.Saved(ctx, "")
	return nil
}

// finish submits the account again after an answer that did not come,
// asking for the terms again when the service changed them.
func (d *loginDriver) finish(ctx context.Context) error {
	accepted := ""
	if d.sh.View().Accept {
		var err error
		if accepted, err = d.accept(ctx); err != nil {
			return err
		}
	}
	d.sh.Saved(ctx, accepted)
	return nil
}

// resume finishes an account an earlier run began making, with its
// recovery code.
func (d *loginDriver) resume(ctx context.Context, v shell.View) error {
	fmt.Fprintf(d.c.out, "This command line began making the account @%s. Type its recovery code to finish it.\n", v.Name)
	code, err := d.c.secret(ctx, "Recovery code: ")
	if err != nil {
		return err
	}
	defer clear(code)
	d.sh.Resume(ctx, string(code))
	return nil
}

func (d *loginDriver) rename(ctx context.Context, v shell.View) error {
	d.name = ""
	name, err := d.askName(ctx, "Another name, yours for life: @")
	if err != nil {
		return err
	}
	d.sh.Rename(ctx, name)
	return nil
}

// askName is the name given with --name, else the one typed.
func (d *loginDriver) askName(ctx context.Context, question string) (string, error) {
	for d.name == "" {
		line, err := d.c.line(ctx, question)
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
