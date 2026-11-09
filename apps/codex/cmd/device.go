// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"maps"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/cyfr/codex/internal/access"
	"github.com/cyfr/codex/internal/account"
	"github.com/cyfr/codex/internal/config"
	"github.com/cyfr/codex/internal/holder"
	"github.com/cyfr/codex/internal/mcp"
	"github.com/cyfr/codex/internal/shell"
	"github.com/spf13/cobra"
)

// The variables cyfr login gives the shell it starts, and only that one:
// the session its unlock holds, for the home it is for, and the process
// that holds it. A command reads the session only for that home's
// address, so no other home is sent it.
const (
	sessionEnv     = "CYFR_SESSION"
	sessionHomeEnv = "CYFR_SESSION_HOME"
	shellPIDEnv    = "CYFR_SHELL_PID"
	// shellPagesEnv says the holding process serves the shell's loopback
	// pages (shell.Origin), through which cyfr open opens Prism.
	shellPagesEnv = "CYFR_SHELL_PAGES"
)

// shellSession is the session cyfr login's shell holds for address, if
// this process runs in that shell and it is that home's.
func shellSession(address string) (string, bool) {
	token, home := os.Getenv(sessionEnv), os.Getenv(sessionHomeEnv)
	if token == "" || home == "" || !sameAddress(home, address) {
		return "", false
	}
	return token, true
}

// deviceKey is where this command line keeps its device key: one key per
// machine, under ~/.cyfr/device, serving every CYFR the person signs in
// to. The client each CYFR admitted it as is kept in that CYFR's context
// (contextClients).
func deviceKey() (string, error) {
	dir, err := config.DefaultConfigDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "device", "key.json"), nil
}

// directoryURL is the directory a new account is made at and a name is
// looked up through: CYFR_DIRECTORY_URL from the environment or from the
// .env here, as the server reads it, else cyfr.run.
func directoryURL() string {
	if v := strings.TrimSpace(os.Getenv(directoryVar)); v != "" {
		return v
	}
	if values, err := access.ReadEnvValues(".env"); err == nil {
		if v := strings.TrimSpace(values[directoryVar]); v != "" {
			return v
		}
	}
	return account.DefaultDirectory
}

const directoryVar = "CYFR_DIRECTORY_URL"

// contextClients keeps the client a CYFR admitted this command line as in
// the context at that CYFR's address: the context the command names when
// it is at that address, else the first at it by name, else a new one
// named by the address's host.
type contextClients struct{ address string }

func (c contextClients) Load() (shell.ClientRecord, error) {
	cfg, err := config.Load()
	if err != nil {
		return shell.ClientRecord{}, err
	}
	if _, at := contextAt(cfg, c.address); at != nil {
		return shell.ClientRecord{ClientID: at.ClientID, Certificate: at.Certificate}, nil
	}
	return shell.ClientRecord{}, nil
}

func (c contextClients) Save(r shell.ClientRecord) error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}
	_, at := contextAt(cfg, c.address)
	if at == nil {
		at = &config.Context{URL: c.address}
		cfg.Contexts[newContextName(cfg, c.address)] = at
	}
	at.ClientID, at.Certificate = r.ClientID, r.Certificate
	return cfg.Save()
}

func contextAt(cfg *config.Config, address string) (string, *config.Context) {
	if at := cfg.Contexts[contextName(cfg)]; at != nil && sameAddress(at.URL, address) {
		return contextName(cfg), at
	}
	for _, name := range slices.Sorted(maps.Keys(cfg.Contexts)) {
		if at := cfg.Contexts[name]; at != nil && sameAddress(at.URL, address) {
			return name, at
		}
	}
	return "", nil
}

// newContextName is a context name for address no context holds: its
// host, numbered when that name is taken.
func newContextName(cfg *config.Config, address string) string {
	base := "cyfr"
	if u, err := url.Parse(address); err == nil && u.Hostname() != "" {
		base = u.Hostname()
	}
	name := base
	for i := 2; cfg.Contexts[name] != nil; i++ {
		name = base + "-" + strconv.Itoa(i)
	}
	return name
}

// deviceOptions is what a command line's shell is built for: the CYFR's
// address, the invitation a new person joins by, the setup token a first
// person is set up by, and what to do when it locks.
type deviceOptions struct {
	address    string
	invitation string
	setupToken string
	locked     func()
	// session is the session a change to confirm is read through, when
	// it is not the one cyfr login's shell holds in its environment.
	session string
}

// device is this command line's device as cyfr login, a confirmation on
// it and the shell it holds drive it: *shell.Shell, which a test stands
// in for.
type device interface {
	View() shell.View
	Begin()
	Make(secret, again []byte)
	Setup(ctx context.Context, name, accepted string, secret, again []byte)
	Create(ctx context.Context, name, accepted string)
	Terms(ctx context.Context) (*account.Policy, error)
	Enroll(ctx context.Context, name string, wait time.Duration)
	CheckListed(ctx context.Context)
	Saved(ctx context.Context, accepted string)
	Resume(ctx context.Context, code string)
	Rename(ctx context.Context, name string)
	Unlock(ctx context.Context, secret []byte)
	Session(ctx context.Context) (string, error)
	Draw(ctx context.Context, ref string)
	Decide(ctx context.Context, ref string, confirm bool, secret []byte)
	Unlocked() bool
	Lock(why string)
}

// openDevice is how a command opens this command line's device: its shell
// (deviceShell), reading a change to confirm through cyfr login's session
// when the command runs in that shell (sessionDevice), unless a test
// stands in for it.
var openDevice = func(o deviceOptions) (device, error) {
	sh, err := deviceShell(o)
	if err != nil {
		return nil, err
	}
	d := &sessionDevice{Shell: sh}
	token, ok := o.session, o.session != ""
	if !ok {
		token, ok = shellSession(o.address)
	}
	if ok {
		d.session = mcp.NewClient(o.address)
		d.session.SessionID = token
	}
	return d, nil
}

// deviceChip is whether this machine offers a chip to hold the command
// line's key (holder.ChipPresent); a test stands in for it, so none
// reaches the machine's own TPM.
var deviceChip = holder.ChipPresent

// deviceHome is the CYFR at address as it names itself in what its
// device signs: a loopback IP spelled localhost (browserAddress), the
// address CYFR on this computer serves itself under, which the local
// context cyfr init saves (http://127.0.0.1:<port>) reaches.
func deviceHome(address string) string {
	u, err := url.Parse(strings.TrimRight(address, "/"))
	if err != nil {
		return address
	}
	return browserAddress(u)
}

// deviceShell is this command line's device at the CYFR at o.address: the
// machine's key, a holder made here (the chip, else a passphrase), named
// by this machine's name, its client there kept in that CYFR's context.
func deviceShell(o deviceOptions) (*shell.Shell, error) {
	path, err := deviceKey()
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, fmt.Errorf("could not make the directory for this command line's key: %w", err)
	}
	return shell.New(shell.Config{
		Address:     deviceHome(o.address),
		Record:      path,
		Clients:     contextClients{address: o.address},
		Directory:   directoryURL(),
		DataDir:     filepath.Dir(path),
		Noun:        "command line",
		Chip:        deviceChip,
		DisplayName: deviceName(),
		Invitation:  o.invitation,
		Tokens:      func() string { return o.setupToken },
		Restart:     o.locked,
	})
}

// deviceName is the name CYFR lists this command line by: "cyfr on"
// and this machine's name, at most 64 bytes.
func deviceName() string {
	name := "cyfr on " + machineName()
	for len(name) > 64 {
		_, size := utf8.DecodeLastRuneInString(name)
		name = name[:len(name)-size]
	}
	return name
}

// console is the person's terminal, as cyfr login and a confirmation on
// this command line talk to it: lines read from one reader for the
// process (stdinLines), and secrets read with the terminal's echo off.
type console struct {
	out   io.Writer
	lines func() <-chan []byte
	// quiet turns the terminal's echo off until the returned function
	// restores it; a test stands in for it.
	quiet func() func()
}

// newConsole is cyfr login's console: each question reads its own line
// (askedLine), so no read of the terminal is left waiting once the last
// question is answered, and the shell cyfr login starts reads every line
// typed after it.
func newConsole(out io.Writer) *console {
	return &console{out: out, lines: func() <-chan []byte { return askedLine(os.Stdin) }, quiet: echoOff}
}

// askedLine reads one line from in, a byte at a time so nothing past its
// newline is taken, and delivers it, without the newline, on the channel
// it answers; the channel closes when the input ends first.
func askedLine(in io.Reader) <-chan []byte {
	ch := make(chan []byte, 1)
	go func() {
		var line []byte
		b := make([]byte, 1)
		for {
			n, err := in.Read(b)
			if n == 1 && b[0] == '\n' {
				ch <- bytes.TrimRight(line, "\r")
				return
			}
			if n == 1 {
				line = append(line, b[0])
			}
			if err != nil {
				clear(line)
				close(ch)
				return
			}
		}
	}()
	return ch
}

// errInputEnded is the input ending before the person answered.
var errInputEnded = errors.New("The input ended before you answered; nothing more was done.")

// line asks question and answers the line typed, without its newline.
func (t *console) line(ctx context.Context, question string) ([]byte, error) {
	fmt.Fprint(t.out, question)
	select {
	case <-ctx.Done():
		fmt.Fprintln(t.out)
		return nil, interruption{errors.New("Interrupted.")}
	case line, open := <-t.lines():
		if !open {
			fmt.Fprintln(t.out)
			return nil, errInputEnded
		}
		return line, nil
	}
}

// secret asks question with the echo off and answers what was typed, as
// bytes the caller erases.
func (t *console) secret(ctx context.Context, question string) ([]byte, error) {
	restore := t.quiet()
	defer restore()
	b, err := t.line(ctx, question)
	fmt.Fprintln(t.out)
	return b, err
}

// stdinLines is the person's lines on standard input, each its own byte
// slice that its reader may erase, read by one reader for the whole
// process: a read cannot be cancelled, so a second reader would race the
// first for the next line. The channel closes at end of input.
var stdinLines = sync.OnceValue(func() <-chan []byte {
	lines := make(chan []byte)
	go func() {
		defer close(lines)
		r := bufio.NewReaderSize(os.Stdin, 64<<10)
		for {
			line, err := r.ReadSlice('\n')
			if len(line) > 0 || err == nil {
				// A copy of the line alone, so the reader's buffer keeps
				// no secret once it is read.
				out := bytes.Clone(bytes.TrimRight(line, "\r\n"))
				clear(line)
				lines <- out
			}
			if err != nil && !errors.Is(err, bufio.ErrBufferFull) {
				return
			}
		}
	}()
	return lines
})

var deviceCmd = &cobra.Command{
	Use:     "device",
	Short:   "Add a device to your account from this command line",
	GroupID: "identity",
}

var deviceApproveCmd = &cobra.Command{
	Use:   "approve <key>",
	Short: "Add the device whose key a new device shows to your account",
	Long: `Add a new device to your account: a command line running cyfr login for
the first time, or a CYFR box's screen, shows its code and this command
with its key. Check that the code printed here is the one the new device
shows, then unlock this command line: its key signs the addition, and the
new device goes on by itself once your account lists it.`,
	Example: "  cyfr device approve VuvwnjcI5bKkUvYLeH7B7Y-xHIrpKvaDLettMxKZg2c",
	// The one argument is taken raw, no flag parsed: a device's key is
	// base64url, which starts with `-` one time in 64, and a parser would
	// read such a key as flags and refuse the command as the new device
	// shows it. The approval reads none of the root's flags (the key record
	// names the directory), and --help or -h alone still prints the help.
	DisableFlagParsing: true,
	Args:               cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		if args[0] == "--help" || args[0] == "-h" {
			return cmd.Help()
		}
		return approveDevice(cmd.Context(), newConsole(os.Stdout), strings.TrimSpace(args[0]))
	},
}

func init() {
	deviceCmd.AddCommand(deviceApproveCmd)
	rootCmd.AddCommand(deviceCmd)
}

// approveDevice adds the device key text names to the account this
// command line's key is listed in, signed by that key after its unlock.
func approveDevice(ctx context.Context, c *console, text string) error {
	pub, ok := account.UnB64(text, 32, 32)
	if !ok {
		return errors.New("That is not a device's key: copy the whole key the new device shows after cyfr device approve.")
	}
	path, err := deviceKey()
	if err != nil {
		return err
	}
	rec, err := holder.Load(path)
	switch {
	case errors.Is(err, fs.ErrNotExist):
		return errors.New("This command line has no key yet: run cyfr login first, then approve the new device from here.")
	case err != nil:
		return fmt.Errorf("This command line's key record %s cannot be read (%v).", path, err)
	case rec.Identifier == "":
		return errors.New("This command line is not on your account yet: run cyfr login first, then approve the new device from here.")
	}
	fmt.Fprintf(c.out, "Adding the device whose code is %s to your account. Check that the new device shows this code.\n", account.ShortCode(account.Kid(pub)))
	question := "Unlock this command line with its passphrase to add it: "
	if rec.Kind == holder.KindChip {
		question = "Unlock this command line with its PIN to add it: "
	}
	secret, err := c.secret(ctx, question)
	if err != nil {
		return err
	}
	key, err := rec.Open(secret)
	clear(secret)
	if errors.Is(err, holder.ErrWrongSecret) || errors.Is(err, holder.ErrSecretShape) {
		return errors.New("That is not this command line's PIN or passphrase. Nothing was added.")
	}
	if err != nil {
		return fmt.Errorf("This command line's key did not open (%v). Nothing was added.", err)
	}
	defer key.Erase()
	d := account.Directory{URL: rec.Directory, Client: &http.Client{}}
	err = account.Approve(ctx, d, rec.Identifier, rec.PublicKey, key.Sign, pub, time.Now().UnixMilli())
	switch {
	case errors.Is(err, account.ErrListed):
		fmt.Fprintln(c.out, "Your account lists that device already.")
		return nil
	case errors.Is(err, account.ErrNotListed):
		return errors.New("Your account does not list this command line any more, so it cannot add a device. Add it from a device of yours that your account lists.")
	case errors.Is(err, account.ErrUnreachable):
		return errors.New("Your account could not be reached just now. Run cyfr device approve again; nothing was added twice.")
	case err != nil:
		return fmt.Errorf("The device was not added: %v.", err)
	}
	fmt.Fprintln(c.out, "Added. The new device goes on by itself.")
	return nil
}
