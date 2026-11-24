// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package shell

import (
	"errors"
	"io/fs"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// One machine key serves one account at every CYFR: a second CYFR whose
// account service is that account's admits the key on its own, with a
// client and certificate of its own beside the first's, which stand; a
// CYFR whose account service is another refuses it, saying so, and nothing
// is sent there.
func TestOneKeyIsAdmittedAtEachCYFRAndRefusedAtAnotherAccountService(t *testing.T) {
	first := newFakeHome(t)
	dir := t.TempDir()
	b := newBox(t, first, dir)
	p := setUpAndOpen(t, first, b)
	b.post("/lock", nil)

	// Another CYFR of the same account service, which admits members of
	// that account.
	second := newFakeHome(t)
	second.accounts = first.accounts
	second.mu.Lock()
	second.openDoor = true
	second.mu.Unlock()
	there := newBoxAt(t, second, dir, first.accounts.URL())
	ticketOf(t, there.post("/unlock", url.Values{"secret": {p}}), second)
	there.post("/lock", nil)
	l, err := Homes(filepath.Join(dir, "homes.json")).Load()
	if err != nil {
		t.Fatal(err)
	}
	at, here := l.Homes[second.address()], l.Homes[first.address()]
	if at.ClientID == "" || len(at.Certificate) == 0 || here.ClientID == "" || len(here.Certificate) == 0 ||
		string(at.Certificate) == string(here.Certificate) {
		t.Fatalf("the two CYFRs' standings are %+v and %+v", here, at)
	}
	if !strings.Contains(string(at.Certificate), second.address()) || !strings.Contains(string(here.Certificate), first.address()) {
		t.Fatalf("a certificate is for another CYFR: %s / %s", here.Certificate, at.Certificate)
	}
	// The first CYFR still opens on its own certificate.
	b = newBox(t, first, dir)
	hellos := len(first.hellosSeen())
	ticketOf(t, b.post("/unlock", url.Values{"secret": {p}}), first)
	if len(first.hellosSeen()) != hellos {
		t.Fatal("the first CYFR was introduced again after the second admitted the key")
	}
	b.post("/lock", nil)

	// A CYFR whose account service is another.
	elsewhere := newFakeHome(t)
	other := newBoxAt(t, elsewhere, dir, elsewhere.accounts.URL())
	other.post("/unlock", url.Values{"secret": {p}})
	want := "This device's account is at the account service " + first.accounts.URL() + ", not at " +
		elsewhere.accounts.URL() + ", which this CYFR uses, so nothing was sent there."
	if other.shell.Unlocked() || len(elsewhere.hellosSeen()) != 0 || !strings.Contains(other.page(), want) {
		t.Fatalf("a CYFR of another account service: unlocked %v, %d hellos, page\n%s", other.shell.Unlocked(),
			len(elsewhere.hellosSeen()), other.page())
	}
	if _, listed := mustLoad(t, dir).Homes[elsewhere.address()]; listed {
		t.Fatal("the refused CYFR was added to the list")
	}
}

func mustLoad(t *testing.T, dir string) HomeList {
	t.Helper()
	l, err := Homes(filepath.Join(dir, "homes.json")).Load()
	if err != nil {
		t.Fatal(err)
	}
	return l
}

// A shell that may not make the key (a box's screen at a CYFR other than
// its own) offers no way to make one, says where it is made, and refuses
// every try, a forged one included, with no key written and nothing asked
// of the CYFR; the same shell given leave makes it.
func TestAShellThatMayNotMakeTheKeyMakesNone(t *testing.T) {
	const where = "This box's key is made at This box first."
	home := newFakeHome(t)
	dir := t.TempDir()
	b := newBoxAt(t, home, dir, home.accounts.URL(), func(c *Config) { c.KeyElsewhere = where })
	page := b.page()
	if !strings.Contains(page, where) || strings.Contains(page, `action="/setup"`) || strings.Contains(page, `action="/make"`) ||
		strings.Contains(page, `action="/passphrase"`) {
		t.Fatalf("the page of a shell that may not make the key:\n%s", page)
	}
	// A passphrase shown, if one were, is the one a try would use.
	pass := "correct horse battery staple again twice"
	b.post("/passphrase", nil)
	if drawn := b.shell.drawPassphrase(t.Context()); drawn != "" {
		pass = drawn
	}
	for _, path := range []string{"/setup", "/make"} {
		b.post(path, url.Values{"name": {"alice"}, "secret": {pass}, "again": {pass}})
	}
	if _, err := os.Stat(b.record); !errors.Is(err, fs.ErrNotExist) || len(home.hellosSeen()) != 0 {
		t.Fatalf("a key was made (%v) or the CYFR was asked (%d hellos)", err, len(home.hellosSeen()))
	}
	if page := b.page(); !strings.Contains(page, where) {
		t.Fatalf("the refusal does not say where the key is made:\n%s", page)
	}
	b = newBox(t, home, dir)
	setUpAndOpen(t, home, b)
}
