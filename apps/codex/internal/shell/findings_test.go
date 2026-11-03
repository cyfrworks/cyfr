// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package shell

import (
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	"github.com/cyfr/codex/internal/holder"
)

func TestRestore_AnInterruptedRestoreFinishesWithTheSavedKey(t *testing.T) {
	home := newFakeHome(t)
	home.restoreToken = strings.Repeat("ab", 32)
	dir := t.TempDir()
	first := newBox(t, home, dir)
	p := first.passphrase()
	home.downComplete = true
	first.post("/restore", url.Values{"code": {"CYFR-RIGHT-CODE"}, "secret": {p}, "again": {p}})
	if home.completes != 0 {
		t.Fatal("setup committed unexpectedly")
	}
	next := newBox(t, home, dir)
	next.post("/finish", url.Values{"code": {"CYFR-RIGHT-CODE"}, "secret": {p}})
	if !next.shell.Unlocked() {
		t.Fatalf("restore with persisted key cannot finish after restart: %s", next.page())
	}
	rec, _ := holder.Load(next.record)
	if len(home.enrolled) != 1 || home.completes != 1 {
		t.Fatalf("enrolled %d keys in %d completes", len(home.enrolled), home.completes)
	}
	for _, e := range home.enrolled {
		if string(e.key) != string(rec.PublicKey) {
			t.Fatal("the restore finished with another key than the saved one")
		}
	}
}

func TestUnlock_ASuspendedScreenOffersTheRecoveryCode(t *testing.T) {
	home := newFakeHome(t)
	b := newBox(t, home, t.TempDir())
	p := setUpAndOpen(t, home, b)
	b.shell.Lock("")
	home.mu.Lock()
	home.closeWith = 4403
	home.mu.Unlock()
	b.post("/unlock", url.Values{"secret": {p}})
	if page := b.page(); !strings.Contains(page, `name="code"`) {
		t.Fatalf("screen whose standing ended offers no recovery-code route: %s", page)
	}
}

func TestEnroll_ARedirectNeverCarriesTheSetupTokenElsewhere(t *testing.T) {
	home := newFakeHome(t)
	leaked := make(chan string, 1)
	other := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.ReadAll(r.Body)
		leaked <- r.Header.Get("X-Cyfr-Setup-Token")
		w.WriteHeader(401)
	}))
	defer other.Close()
	home.srv.Config.Handler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, other.URL+"/capture", http.StatusTemporaryRedirect)
	})
	b := newBox(t, home, t.TempDir())
	b.setUp("alice")
	select {
	case token := <-leaked:
		t.Fatalf("enrollment redirect disclosed setup credential to another origin: %q", token)
	default:
	}
}
