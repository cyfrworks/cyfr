// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build unix

package cmd

import (
	"os"
	"syscall"
	"testing"

	"github.com/cyfr/codex/internal/config"
)

// swapConfigAfterFirstRead serves the configuration's first reader the
// file as it is now, and every later reader next: the path becomes a FIFO
// whose writer, once a reader opens it, saves next over the path, as any
// cyfr command saves it, and only then writes the first reader its old
// bytes. So another command's write lands between this command's first
// read of its context and any later read, every time.
func swapConfigAfterFirstRead(t *testing.T, path string, next *config.Config) <-chan error {
	t.Helper()
	initial, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if err := syscall.Mkfifo(path, 0o600); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() {
		fifo, err := os.OpenFile(path, os.O_WRONLY, 0)
		if err != nil {
			done <- err
			return
		}
		defer fifo.Close()
		if err := next.SaveTo(path); err != nil {
			done <- err
			return
		}
		_, err = fifo.Write(initial)
		done <- err
	}()
	return done
}

// Login signs in at the context it validated and saves there, though
// another command makes another context current right after that read:
// the client is built from the validated read, never from a second one.
func TestLogin_UsesTheContextItValidated(t *testing.T) {
	home := newStubHome(t, "approved")
	other := newStubHome(t, "approved")
	path := withContexts(t, "home", map[string]*config.Context{
		"home": {URL: home.URL}, "other": {URL: other.URL},
	})
	next := loadContexts(t, path)
	next.CurrentContext = "other"
	done := swapConfigAfterFirstRead(t, path, next)

	out, err := runLogin(t, t.Context(), "login")
	if changed := <-done; changed != nil {
		t.Fatal(changed)
	}
	if err != nil {
		t.Fatalf("login: %v\n%s", err, out)
	}
	if _, began := home.call("cli_begin"); !began {
		t.Errorf("the validated home was asked nothing: %v", home.actions())
	}
	if n := len(other.actions()); n != 0 {
		t.Errorf("the other context's home was asked %d things", n)
	}
	cfg := loadContexts(t, path)
	if cfg.Contexts["home"].Token != stubToken || cfg.Contexts["other"].Token != "" {
		t.Errorf("the session was saved under the wrong context: home %q, other %q",
			cfg.Contexts["home"].Token, cfg.Contexts["other"].Token)
	}
}

// Logout sends the validated context's own credential to its own address,
// and clears that context alone, though another context becomes current
// right after the validating read.
func TestLogout_UsesTheContextItValidated(t *testing.T) {
	home := newStubHome(t)
	other := newStubHome(t)
	path := withContexts(t, "home", map[string]*config.Context{
		"home":  {URL: home.URL, Token: "home-session"},
		"other": {URL: other.URL, Token: "other-session"},
	})
	next := loadContexts(t, path)
	next.CurrentContext = "other"
	done := swapConfigAfterFirstRead(t, path, next)

	out, err := runLogin(t, t.Context(), "logout", "--url", home.URL)
	if changed := <-done; changed != nil {
		t.Fatal(changed)
	}
	if err != nil {
		t.Fatalf("logout: %v\n%s", err, out)
	}
	if c, ok := home.call("logout"); !ok || c.authorization != "Bearer home-session" {
		t.Errorf("the validated home's logout carried %q (asked: %v)", c.authorization, ok)
	}
	if n := len(other.actions()); n != 0 {
		t.Errorf("the other context's home was asked %d things", n)
	}
	cfg := loadContexts(t, path)
	if cfg.Contexts["home"].Token != "" || cfg.Contexts["other"].Token != "other-session" {
		t.Errorf("logout cleared the wrong context: home %q, other %q",
			cfg.Contexts["home"].Token, cfg.Contexts["other"].Token)
	}
}
