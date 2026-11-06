// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"unicode/utf8"

	"github.com/cyfr/codex/internal/config"
	"github.com/cyfr/codex/internal/holder"
	"github.com/cyfr/codex/internal/mcp"
	"github.com/cyfr/codex/internal/shell"
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

// deviceRecord is where this command line keeps its device key for the
// home at address: one record per home, under ~/.cyfr/devices, named by
// the digest of the address, so a context that moves to another address
// finds no key there and pairs again.
func deviceRecord(address string) (string, error) {
	dir, err := config.DefaultConfigDir()
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256([]byte(normalAddress(address)))
	return filepath.Join(dir, "devices", hex.EncodeToString(sum[:12])+".json"), nil
}

// normalAddress is an address as sameAddress compares it: scheme and host
// folded to lower case, no trailing slash.
func normalAddress(address string) string {
	u, err := url.Parse(strings.TrimRight(address, "/"))
	if err != nil {
		return address
	}
	u.Scheme, u.Host = strings.ToLower(u.Scheme), strings.ToLower(u.Host)
	return u.String()
}

// deviceOptions is what a command line's shell is built for: the home's
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
	Setup(ctx context.Context, name string, secret, again []byte)
	Join(ctx context.Context, invitation, name string, secret, again []byte)
	Prepare(secret, again []byte)
	Pair(ctx context.Context, link string, secret []byte)
	Finish(ctx context.Context, name, code string, secret []byte)
	Unlock(ctx context.Context, secret []byte)
	Saved(ctx context.Context)
	Rename(ctx context.Context, name string)
	Session(ctx context.Context) (string, error)
	Draw(ctx context.Context, ref string)
	Decide(ctx context.Context, ref string, confirm bool, secret []byte)
	Unlocked() bool
	Lock(why string)
	Reenable(ctx context.Context, code string, secret []byte)
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

// deviceHome is the home at address as it names itself in what its
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

// deviceShell is this command line's device for the home at o.address:
// its key record, a holder made on this machine (the chip, else a
// passphrase), named by this machine's name, which pairs through the
// home's pairing.complete, asked anonymously. A record of another home at
// this path, which no address change makes valid, is not read.
func deviceShell(o deviceOptions) (*shell.Shell, error) {
	path, err := deviceRecord(o.address)
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, fmt.Errorf("could not make the directory for this command line's key: %w", err)
	}
	home := deviceHome(o.address)
	if rec, err := holder.Load(path); err == nil && !sameAddress(rec.Home, home) {
		return nil, fmt.Errorf("the key record %s is for %s, not %s: remove it, then run cyfr login again", path, rec.Home, home)
	} else if err != nil && !errors.Is(err, fs.ErrNotExist) {
		return nil, fmt.Errorf("this command line's key record %s cannot be read (%v)", path, err)
	}
	return shell.New(shell.Config{
		Address:     home,
		Record:      path,
		DataDir:     filepath.Dir(path),
		Noun:        "command line",
		Chip:        deviceChip,
		DisplayName: deviceName(),
		Invitation:  o.invitation,
		HomeHere:    homeHere(o.address),
		Tokens:      func() (string, string) { return o.setupToken, "" },
		Restart:     o.locked,
	})
}

// deviceName is the name Devices lists this command line by: "cyfr on"
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
