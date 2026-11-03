// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package shell

import (
	"bytes"
	"net/http"
	"net/url"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/cyfr/codex/internal/holder"
)

func TestReview490_CommittedRestoreResumesAfterItsAnswerWasLost(t *testing.T) {
	home := newFakeHome(t)
	home.restoreToken = strings.Repeat("ab", 32)
	home.dropComplete = true
	var disconnected atomic.Bool
	disconnected.Store(true)
	base := home.srv.Config.Handler
	home.srv.Config.Handler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/device/enrollment/resume" && disconnected.Load() {
			reply(w, 503, map[string]any{"error": "unavailable"})
			return
		}
		home.mu.Lock()
		committed := home.completes != 0
		home.mu.Unlock()
		// Recovery.restore returns restored after completion. Its reproof
		// challenge returns closed once enrollment used the first method.
		if committed && (r.URL.Path == "/restore" || r.URL.Path == "/restore/challenge") {
			code := "restored"
			if r.URL.Path == "/restore/challenge" {
				code = "closed"
			}
			reply(w, 409, map[string]any{"error": code})
			return
		}
		base.ServeHTTP(w, r)
	})

	dir := t.TempDir()
	first := newBox(t, home, dir)
	p := first.passphrase()
	first.post("/restore", url.Values{"code": {"CYFR-RIGHT-CODE"}, "secret": {p}, "again": {p}})
	saved, err := holder.Load(first.record)
	if err != nil || saved == nil || len(saved.Certificate) != 0 || home.completes != 1 {
		t.Fatalf("the lost answer did not leave one committed key and its unfinished local record: %v", err)
	}

	disconnected.Store(false)
	next := newBox(t, home, dir)
	next.post("/finish", url.Values{"code": {"CYFR-RIGHT-CODE"}, "secret": {p}})
	if !next.shell.Unlocked() {
		t.Fatalf("a committed restore cannot resume its saved key: completes=%d resumes=%d page=%s", home.completes, home.resumes, next.page())
	}
	finished, err := holder.Load(next.record)
	if err != nil || !bytes.Equal(finished.PublicKey, saved.PublicKey) || home.completes != 1 || len(home.enrolled) != 1 {
		t.Fatal("finishing must recover the committed certificate without replacing or enrolling the key again")
	}
}
