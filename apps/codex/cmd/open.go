// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"runtime"

	"golang.org/x/term"
)

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

// openOnDisplay opens address in the default browser,
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
