// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"errors"
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
	if !reflect.DeepEqual(*opened, []string{home.URL}) {
		t.Errorf("opened %v, want the context's address alone", *opened)
	}
	if n := len(home.actions()); n != 0 {
		t.Errorf("open asked the home %d things", n)
	}
	if strings.Contains(out, "home-session") {
		t.Errorf("open printed the session:\n%s", out)
	}

	*opened = nil
	if out, err := runLogin(t, t.Context(), "open"); err != nil || !reflect.DeepEqual(*opened, []string{"http://127.0.0.1:4000"}) {
		t.Fatalf("open of the current context: %v, opened %v\n%s", err, *opened, out)
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
