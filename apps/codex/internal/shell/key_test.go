// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package shell

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/cyfr/codex/internal/disk"
	"github.com/cyfr/codex/internal/holder"
)

// firstUse is a shell over the machine's key at path that has read no
// record yet, as a first cyfr login does.
func firstUse(t *testing.T, home *fakeHome, path string) *Shell {
	t.Helper()
	cfg := Config{Address: "https://one.example", Record: path, DataDir: filepath.Dir(path), Clients: &memoryClients{},
		Chip: func() bool { return false }, Detect: func(string) disk.Report { return disk.Report{} }, Noun: "command line"}
	if home != nil {
		cfg.Address, cfg.Client, cfg.Directory = home.address(), home.srv.Client(), home.accounts.URL()
	}
	sh, err := New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { sh.Lock("") })
	return sh
}

// Two first logins opened together keep one machine key: the second's
// Make finds the key the first already showed for approval and uses it,
// saying so, and never replaces it.
func TestTwoFirstLoginsKeepTheMachineKey(t *testing.T) {
	path := filepath.Join(t.TempDir(), "key.json")
	first := firstUse(t, nil, path)
	second := firstUse(t, nil, path)
	firstPhrase := first.View().Passphrase
	secondPhrase := second.View().Passphrase
	first.Make([]byte(firstPhrase), []byte(firstPhrase))
	before, err := holder.Load(path)
	if err != nil {
		t.Fatal(err)
	}
	second.Make([]byte(secondPhrase), []byte(secondPhrase))
	after, err := holder.Load(path)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(before.PublicKey, after.PublicKey) {
		t.Fatal("a second first-login replaced the machine key already shown for approval by the first login")
	}
	v := second.View()
	if v.Page != PageEnroll || v.Key != b64(before.PublicKey) || !strings.Contains(v.Notice, "made its key first") {
		t.Fatalf("the second login shows %s for key %s: %q", v.Page, v.Key, v.Notice)
	}
}

// First uses racing to make the key, each from a shell that read no
// record, leave one key on disk, which every one of them shows; no
// temporary file is left behind.
func TestFirstUsesRacingMakeOneKey(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "key.json")
	shells := make([]*Shell, 6)
	phrases := make([]string, len(shells))
	for i := range shells {
		shells[i] = firstUse(t, nil, path)
		phrases[i] = shells[i].View().Passphrase
	}
	var wg sync.WaitGroup
	for i, sh := range shells {
		wg.Add(1)
		go func() {
			defer wg.Done()
			sh.Make([]byte(phrases[i]), []byte(phrases[i]))
		}()
	}
	wg.Wait()
	held, err := holder.Load(path)
	if err != nil {
		t.Fatal(err)
	}
	makers := 0
	for i, sh := range shells {
		v := sh.View()
		if v.Page != PageEnroll || v.Key != b64(held.PublicKey) {
			t.Errorf("shell %d shows %s for key %s, not the machine's %s", i, v.Page, v.Key, b64(held.PublicKey))
		}
		if v.Notice == "" {
			makers++
		}
	}
	if makers != 1 {
		t.Errorf("%d shells say they made the key", makers)
	}
	if entries, _ := os.ReadDir(dir); len(entries) != 1 {
		t.Errorf("the directory holds %v, want only key.json", entries)
	}
}

// A shell whose key went from under it while it was making an account
// sends nothing of that account and acts on the key the machine keeps
// now, which it never replaces.
func TestAStaleShellNeverReplacesTheKeyThere(t *testing.T) {
	home := newFakeHome(t)
	path := filepath.Join(t.TempDir(), "key.json")
	stale := firstUse(t, home, path)
	p := newSecret(t, stale)
	stale.Make([]byte(string(p)), []byte(string(p)))
	stale.Create(t.Context(), "ada", "")
	if v := stale.View(); v.Page != PageRecovery {
		t.Fatalf("the account shows page %s: %s", v.Page, v.Notice)
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	other := firstUse(t, home, path)
	q := newSecret(t, other)
	other.Make([]byte(string(q)), []byte(string(q)))
	now, _ := holder.Load(path)

	stale.Saved(t.Context(), "")
	held, _ := holder.Load(path)
	v := stale.View()
	if !bytes.Equal(held.PublicKey, now.PublicKey) || held.Identifier != "" || home.accounts.Writes != 0 {
		t.Fatalf("the stale shell wrote over the key, or sent its account (%d writes)", home.accounts.Writes)
	}
	if v.Page != PageEnroll || v.Key != b64(now.PublicKey) {
		t.Fatalf("the stale shell shows %s for key %s", v.Page, v.Key)
	}
}

// Two shells making an account with the one key make one: the second to
// save its code finds the first's attempt and sends nothing, and offers to
// finish the first's with its recovery code; once the first is done, a
// shell holding another attempt drops it.
func TestOneAccountIsMadePerKey(t *testing.T) {
	home := newFakeHome(t)
	path := filepath.Join(t.TempDir(), "key.json")
	first := firstUse(t, home, path)
	p := newSecret(t, first)
	first.Make([]byte(string(p)), []byte(string(p)))
	second := firstUse(t, home, path)
	third := firstUse(t, home, path)
	for name, sh := range map[string]*Shell{"ada": first, "bea": second, "cy": third} {
		sh.Create(t.Context(), name, "")
		if v := sh.View(); v.Page != PageRecovery {
			t.Fatalf("%s: page %s, %s", name, v.Page, v.Notice)
		}
	}
	home.accounts.Down = true
	first.Saved(t.Context(), "")
	home.accounts.Down = false
	second.Saved(t.Context(), "")
	if v := second.View(); v.Page != PageResume || v.Name != "ada" || !strings.Contains(v.Notice, "began an account with this key first") {
		t.Fatalf("the second shows %s for @%s: %q", v.Page, v.Name, v.Notice)
	}
	first.Saved(t.Context(), "")
	rec, _ := holder.Load(path)
	if rec.Identifier == "" || home.accounts.Holder("ada") != rec.Identifier {
		t.Fatalf("the first account was not made: %s", first.View().Notice)
	}
	third.Saved(t.Context(), "")
	if v := third.View(); v.Page != PageLocked || !strings.Contains(v.Notice, "on an account already") {
		t.Fatalf("the third shows %s: %q", v.Page, v.Notice)
	}
	if home.accounts.Holder("bea") != "" || home.accounts.Holder("cy") != "" {
		t.Fatal("another account was made with the key")
	}
}
