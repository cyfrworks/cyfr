// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"errors"
	"net/url"
	"reflect"
	"strings"
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
