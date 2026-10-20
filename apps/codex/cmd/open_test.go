// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bytes"
	"errors"
	"net/url"
	"os"
	"reflect"
	"slices"
	"strings"
	"sync"
	"testing"

	"github.com/cyfr/codex/internal/config"
)

// stubBrowser stands in for the system's opener and records each address
// it was handed.
func stubBrowser(t *testing.T, err error) *[]string {
	t.Helper()
	opened := []string{}
	previous := openBrowser
	openBrowser = func(address string) error {
		opened = append(opened, address)
		return err
	}
	t.Cleanup(func() { openBrowser = previous })
	return &opened
}

// cyfr open hands the context's address to the browser and nothing more:
// no request reaches the home, so no session travels.
func TestOpen_OpensTheContextsAddress(t *testing.T) {
	home := newStubHome(t)
	withContexts(t, "local", map[string]*config.Context{
		"local": {URL: "http://127.0.0.1:4000", Token: "local-session"},
		"home":  {URL: home.URL, Token: "home-session"},
	})
	opened := stubBrowser(t, nil)

	out, err := runLogin(t, t.Context(), "open", "--context", "home")
	if err != nil {
		t.Fatalf("open: %v\n%s", err, out)
	}
	// The stub home listens on a loopback IP, which opens as localhost.
	if want := strings.Replace(home.URL, "127.0.0.1", "localhost", 1); !reflect.DeepEqual(*opened, []string{want}) {
		t.Errorf("opened %v, want the context's address alone, %s", *opened, want)
	}
	if n := len(home.actions()); n != 0 {
		t.Errorf("open asked the home %d things", n)
	}
	if strings.Contains(out, "home-session") {
		t.Errorf("open printed the session:\n%s", out)
	}

	// This machine's loopback context opens as the address a home on this
	// computer serves itself under.
	*opened = nil
	if out, err := runLogin(t, t.Context(), "open"); err != nil || !reflect.DeepEqual(*opened, []string{"http://localhost:4000"}) {
		t.Fatalf("open of the current context: %v, opened %v\n%s", err, *opened, out)
	}
}

// A loopback IP opens as localhost, its port and path kept; any other
// address opens as given.
func TestBrowserAddress_LoopbackIsLocalhost(t *testing.T) {
	for given, want := range map[string]string{
		"http://127.0.0.1:4000":          "http://localhost:4000",
		"http://[::1]:4000/a/b":          "http://localhost:4000/a/b",
		"http://127.0.0.1":               "http://localhost",
		"https://home.tail9f3a3c.ts.net": "https://home.tail9f3a3c.ts.net",
		"http://localhost:4000":          "http://localhost:4000",
		"https://192.0.2.7:8443":         "https://192.0.2.7:8443",
	} {
		u, err := url.Parse(given)
		if err != nil {
			t.Fatal(err)
		}
		if got := browserAddress(u); got != want {
			t.Errorf("%s opens as %s, want %s", given, got, want)
		}
	}
}

// An address that is no web address is refused, and a system with no
// opener prints the address and exits 1.
func TestOpen_RefusesWhatItCannotOpen(t *testing.T) {
	withContexts(t, "odd", map[string]*config.Context{"odd": {URL: "file:///etc/passwd"}})
	opened := stubBrowser(t, nil)

	_, err := runLogin(t, t.Context(), "open")
	if !exitsOne(err) || !strings.Contains(err.Error(), "is not a web address") {
		t.Fatalf("want the address refused, got %v", err)
	}
	if len(*opened) != 0 {
		t.Errorf("opened %v", *opened)
	}

	withContexts(t, "home", map[string]*config.Context{"home": {URL: "https://home.example"}})
	stubBrowser(t, errors.New("no xdg-open to open it with"))
	out, err := runLogin(t, t.Context(), "open")
	if !exitsOne(err) || !strings.Contains(out, "Open https://home.example in your browser.") {
		t.Fatalf("want the address printed and exit 1, got %v\n%s", err, out)
	}
}

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
		"a file, synced":    hyperlink(&syncWriter{w: tempFile(t)}, address),
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
