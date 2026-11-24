// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bytes"
	"os"
	"reflect"
	"slices"
	"sync"
	"testing"
)

// Each system opens the address with its own opener, handed the address
// as one argument and never through a shell.
func TestBrowserCommand_PerSystem(t *testing.T) {
	address := "https://home.example/?a=1&b=2"
	for goos, want := range map[string][]string{
		"linux":   {"xdg-open", address},
		"freebsd": {"xdg-open", address},
		"darwin":  {"open", address},
		"windows": {"rundll32", "url.dll,FileProtocolHandler", address},
	} {
		name, args := browserCommand(goos, address)
		if got := append([]string{name}, args...); !reflect.DeepEqual(got, want) {
			t.Errorf("%s: %v, want %v", goos, got, want)
		}
	}
}

// launched records each address handed to the launcher a test stands in.
type launched struct {
	mu        sync.Mutex
	addresses []string
}

func (l *launched) all() []string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return slices.Clone(l.addresses)
}

// stubLauncher stands a machine with a display, or none, and its launcher
// in, the launcher failing with err.
func stubLauncher(t *testing.T, display bool, err error) *launched {
	t.Helper()
	l := &launched{}
	savedDisplay, savedLaunch := hasDisplay, launchBrowser
	t.Cleanup(func() { hasDisplay, launchBrowser = savedDisplay, savedLaunch })
	hasDisplay = func() bool { return display }
	launchBrowser = func(address string) error {
		l.mu.Lock()
		defer l.mu.Unlock()
		l.addresses = append(l.addresses, address)
		return err
	}
	return l
}

// macOS and Windows always show a browser opened on them; any other
// system only under an X or a Wayland display.
func TestDisplayed_PerSystem(t *testing.T) {
	for _, c := range []struct {
		goos string
		env  map[string]string
		want bool
	}{
		{"darwin", nil, true},
		{"windows", nil, true},
		{"linux", nil, false},
		{"linux", map[string]string{"DISPLAY": ":0"}, true},
		{"linux", map[string]string{"WAYLAND_DISPLAY": "wayland-0"}, true},
		{"freebsd", map[string]string{"DISPLAY": ""}, false},
	} {
		if got := displayed(c.goos, func(k string) string { return c.env[k] }); got != c.want {
			t.Errorf("%s with %v: displayed %v, want %v", c.goos, c.env, got, c.want)
		}
	}
}

// An address is a hyperlink on a terminal that reads the sequence, and
// plain text off a terminal, on Apple Terminal and on a Windows console
// other than Windows Terminal.
func TestHyperlink_OnlyOnATerminalThatShowsIt(t *testing.T) {
	const address = "https://login.tailscale.com/a/abc123"
	env := func(vars map[string]string) func(string) string { return func(k string) string { return vars[k] } }
	link := "\x1b]8;;" + address + "\x1b\\" + address + "\x1b]8;;\x1b\\"
	for name, got := range map[string]string{
		"iTerm":            hyperlinkFor(address, true, "darwin", env(map[string]string{"TERM_PROGRAM": "iTerm.app"})),
		"a Linux terminal": hyperlinkFor(address, true, "linux", env(nil)),
		"Windows Terminal": hyperlinkFor(address, true, "windows", env(map[string]string{"WT_SESSION": "1f0e"})),
	} {
		if got != link {
			t.Errorf("%s: %q, want %q", name, got, link)
		}
	}
	for name, got := range map[string]string{
		"Apple Terminal":    hyperlinkFor(address, true, "darwin", env(map[string]string{"TERM_PROGRAM": "Apple_Terminal"})),
		"a Windows console": hyperlinkFor(address, true, "windows", env(nil)),
		"no terminal":       hyperlinkFor(address, false, "linux", env(nil)),
		"a buffer":          hyperlink(&bytes.Buffer{}, address),
		"a file":            hyperlink(tempFile(t), address),
	} {
		if got != address {
			t.Errorf("%s: %q, want the address as it is", name, got)
		}
	}
}

func tempFile(t *testing.T) *os.File {
	t.Helper()
	f, err := os.CreateTemp(t.TempDir(), "out")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { f.Close() })
	return f
}
