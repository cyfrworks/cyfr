// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"errors"
	"fmt"
	"io"
	"net"
	"net/url"
	"os"
	"os/exec"
	"runtime"

	"github.com/cyfr/codex/internal/config"
	"github.com/cyfr/codex/internal/shell"
	"github.com/spf13/cobra"
	"golang.org/x/term"
)

func init() {
	rootCmd.AddCommand(openCmd)
}

var openCmd = &cobra.Command{
	Use:     "open",
	Short:   "Open Aqua in your browser",
	GroupID: "identity",
	Long: `Open Aqua in your default browser, at CYFR's address: the --url, the
--context's address, the CYFR of the shell cyfr login started, or the
current context's.

In the shell cyfr login started for that CYFR, it opens this command
line's own page, where Open CYFR signs the browser in through this
unlock: CYFR answers a ticket that works once, within a minute, and the
browser spends it for a session of its own, which lives as long as this
command line stays unlocked. No session of the command line's travels to
the browser, and the ticket is in no address this program hands on.

Anywhere else it opens the address and nothing more: sign in there as you
always do. The loopback address cyfr init saves for this machine
(http://127.0.0.1:<port>) opens as http://localhost:<port>, the address
CYFR on this computer serves itself under.`,
	Example: `  cyfr open
  cyfr open --context work`,
	Args: cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		cfg, err := config.Load()
		if err != nil {
			cfg = config.DefaultForLocal()
		}
		address := serverURL(cfg)

		parsed, err := url.Parse(address)
		if err != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") || parsed.Host == "" {
			return fmt.Errorf("%q is not a web address to open: give CYFR's https:// or http:// address", address)
		}
		if _, held := shellSession(address); held && os.Getenv(shellPagesEnv) != "" {
			// The page is the shell's own, on literal loopback: the
			// ticket is answered to its form's POST, in a redirect's
			// fragment, never in this command's arguments.
			if err := openBrowser(shell.Origin + "/"); err != nil {
				fmt.Printf("Open %s/ in your browser on this machine.\n", shell.Origin)
				return fmt.Errorf("Could not open a browser here: %w", err)
			}
			fmt.Printf("Opened this command line's page: press Open CYFR there.\n")
			return nil
		}
		address = browserAddress(parsed)

		if err := openBrowser(address); err != nil {
			fmt.Printf("Open %s in your browser.\n", address)
			return fmt.Errorf("Could not open a browser here: %w", err)
		}
		fmt.Printf("Opened %s\n", address)
		return nil
	},
}

// openBrowser hands address to this system's opener and waits for it,
// which returns once the browser has it. A test stands in for it.
var openBrowser = func(address string) error {
	name, args := browserCommand(runtime.GOOS, address)
	if _, err := exec.LookPath(name); err != nil {
		return errors.New("no " + name + " to open it with")
	}
	opener := exec.Command(name, args...)
	// An opener that falls back to a browser in the terminal needs it.
	opener.Stdin, opener.Stdout, opener.Stderr = os.Stdin, os.Stdout, os.Stderr
	return opener.Run()
}

// launchBrowser hands address to this system's opener (browserCommand)
// without waiting for it, since an opener may wait for the browser to
// exit, and answers only a failure to start it. A test stands in for it.
var launchBrowser = func(address string) error {
	name, args := browserCommand(runtime.GOOS, address)
	if _, err := exec.LookPath(name); err != nil {
		return errors.New("no " + name + " to open it with")
	}
	opener := exec.Command(name, args...)
	if err := opener.Start(); err != nil {
		return err
	}
	go func() { _ = opener.Wait() }()
	return nil
}

// hasDisplay is whether a browser opened on this machine shows on a
// screen (displayed). A test stands in for it.
var hasDisplay = func() bool { return displayed(runtime.GOOS, os.Getenv) }

// displayed is whether the system goos, with the environment getenv,
// shows a browser opened on it: macOS and Windows always, elsewhere only
// under an X or Wayland display, which a headless machine lacks.
func displayed(goos string, getenv func(string) string) bool {
	switch goos {
	case "darwin", "windows":
		return true
	}
	return getenv("DISPLAY") != "" || getenv("WAYLAND_DISPLAY") != ""
}

// openOnDisplay opens address in the default browser, as cyfr open does,
// unless noOpen or there is no display, and answers whether it did; one
// that cannot be opened is said on out. The address is printed before it
// either way.
func openOnDisplay(address string, noOpen bool, out io.Writer) bool {
	if noOpen || !hasDisplay() {
		return false
	}
	if err := launchBrowser(address); err != nil {
		fmt.Fprintf(out, "Could not open a browser here (%v); open the address above.\n", err)
		return false
	}
	return true
}

// hyperlink is address as out shows it: an OSC 8 hyperlink, which a
// terminal shows as the address and opens on a click, when out is a
// terminal that reads the sequence (hyperlinkFor); the address as it is
// otherwise.
func hyperlink(out io.Writer, address string) string {
	if w, ok := out.(*syncWriter); ok {
		out = w.w
	}
	f, ok := out.(*os.File)
	return hyperlinkFor(address, ok && term.IsTerminal(int(f.Fd())), runtime.GOOS, os.Getenv)
}

// hyperlinkFor is hyperlink on a terminal or not, on the system goos with
// the environment getenv. Apple Terminal prints the sequence as text, and
// so does a Windows console this program has not switched to escape
// sequences: on Windows only Windows Terminal (WT_SESSION) reads them.
func hyperlinkFor(address string, terminal bool, goos string, getenv func(string) string) string {
	if !terminal || getenv("TERM_PROGRAM") == "Apple_Terminal" || (goos == "windows" && getenv("WT_SESSION") == "") {
		return address
	}
	return "\x1b]8;;" + address + "\x1b\\" + address + "\x1b]8;;\x1b\\"
}

// browserAddress is the address as a browser should open it: a loopback
// IP spelled localhost, the host a home on this computer serves itself
// under, and the one the passkeys of an account service it serves itself
// are registered for, which an IP address never is.
func browserAddress(u *url.URL) string {
	if ip := net.ParseIP(u.Hostname()); ip != nil && ip.IsLoopback() {
		opened := *u
		opened.Host = "localhost"
		if port := u.Port(); port != "" {
			opened.Host = "localhost:" + port
		}
		return opened.String()
	}
	return u.String()
}

// browserCommand is the command that opens address on the system goos:
// open on macOS, the URL protocol handler on Windows (start is a shell
// built-in, and a shell would read the address's & as its own), and
// xdg-open elsewhere.
func browserCommand(goos, address string) (string, []string) {
	switch goos {
	case "darwin":
		return "open", []string{address}
	case "windows":
		return "rundll32", []string{"url.dll,FileProtocolHandler", address}
	default:
		return "xdg-open", []string{address}
	}
}
