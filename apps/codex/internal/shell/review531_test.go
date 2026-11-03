// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package shell

import (
	"bytes"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync/atomic"
	"testing"
)

func TestReview531_RefusedResumeDoesNotSendTheRecoveryCode(t *testing.T) {
	home := newFakeHome(t)
	home.restoreToken = strings.Repeat("ab", 32)
	home.dropComplete = true
	var restarting atomic.Bool
	base := home.srv.Config.Handler
	var reproofs atomic.Int32
	home.srv.Config.Handler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/device/enrollment/resume" {
			if !restarting.Load() {
				reply(w, 503, map[string]any{"error": "unavailable"})
				return
			}
			raw, _ := io.ReadAll(r.Body)
			r.Body = io.NopCloser(bytes.NewReader(raw))
			// The client was found and its challenge answered. Losing that
			// challenge before the proof is verified refuses the proof.
			if bytes.Contains(raw, []byte(`"proof"`)) {
				reply(w, 422, map[string]any{"error": "proof_refused"})
				return
			}
		}
		if restarting.Load() && r.URL.Path == "/restore" {
			reproofs.Add(1)
			reply(w, 409, map[string]any{"error": "restored"})
			return
		}
		if r.URL.Path == "/restore/challenge" {
			reply(w, 409, map[string]any{"error": "closed"})
			return
		}
		base.ServeHTTP(w, r)
	})
	dir := t.TempDir()
	first := newBox(t, home, dir)
	p := first.passphrase()
	first.post("/restore", url.Values{"code": {"CYFR-RIGHT-CODE"}, "secret": {p}, "again": {p}})
	if home.completes != 1 {
		t.Fatal("the restore must have one committed client")
	}

	restarting.Store(true)
	next := newBox(t, home, dir)
	next.post("/finish", url.Values{"code": {"CYFR-RIGHT-CODE"}, "secret": {p}})
	if got := reproofs.Load(); got != 0 {
		t.Fatalf("resume refused the proof, not a missing client, but Finish sent the recovery code %d times: %s", got, next.page())
	}
	if next.shell.Unlocked() || home.completes != 1 || !strings.Contains(next.page(), "proof_refused") {
		t.Fatal("a refused resume must preserve its refusal and enroll nothing")
	}
}
