// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package shell

import (
	"errors"
	"net/http"
	"path/filepath"
	"strings"
	"testing"

	"github.com/cyfr/codex/internal/holder"
)

func TestReviewS3BResetFailureStaysVisibleAfterConfirmation(t *testing.T) {
	for _, terminal := range []bool{false, true} {
		name := "screen"
		if terminal {
			name = "terminal"
		}
		t.Run(name, func(t *testing.T) {
			home := newFakeHome(t)
			sh, _ := pinned(t, home, t.TempDir())
			if !terminal {
				sh.Unlock(t.Context(), []byte("123456"))
				if !sh.Unlocked() {
					t.Fatal(sh.View().Notice)
				}
			}
			home.pending["cnr_1"] = map[string]any{"ref": "cnr_1", "operation": "pairing.begin", "preview": map[string]any{"key_digest": "D1"}}
			before := home.pin.charged
			sh.cfg.Client.Transport = reviewPINResetTransport{next: http.DefaultTransport}
			if terminal {
				sh.ConfirmDrawn(t.Context(), PendingConfirm{Ref: "cnr_1", Operation: "pairing.begin", Preview: map[string]any{"key_digest": "D1"}}, []byte("123456"))
			} else {
				sh.Draw(t.Context(), "cnr_1")
				sh.Decide(t.Context(), "cnr_1", true, []byte("123456"))
			}
			attempts, _, _ := home.pin.state(home.pin.id(0))
			if len(home.confirmed) != 1 || home.pin.charged != before+1 || attempts != 1 {
				t.Fatalf("confirmation=%d evaluations=%d attempts=%d notice=%q", len(home.confirmed), home.pin.charged-before, attempts, sh.View().Notice)
			}
			if notice := sh.View().Notice; !strings.Contains(notice, "reset") {
				t.Fatalf("the confirmation hid its failed reset and retained charge: %q", notice)
			}
		})
	}
}

func TestReviewS3BForgedPendingMarkCannotSkipEvaluationOrReset(t *testing.T) {
	home := newFakeHome(t)
	dir := t.TempDir()
	sh := pinLine(t, home, dir, false)
	pairOnBox(t, home, sh)
	sh.cfg.Client.Transport = reviewPINResetTransport{next: http.DefaultTransport}
	sh.SetPIN(t.Context(), []byte("123456"), []byte("123456"))
	sh.Lock("")
	rec := record(t, dir)
	if !rec.PIN.Pending {
		t.Fatal("the failed first reset left no pending mark")
	}
	rec.PIN.Pending = false
	if err := rec.Save(filepath.Join(dir, "device.json")); err != nil {
		t.Fatal(err)
	}
	if _, err := rec.Open([]byte("123456")); !errors.Is(err, holder.ErrNeedsHome) {
		t.Fatalf("a forged mark permitted an offline open: %v", err)
	}
	rebooted := pinLine(t, home, dir, false)
	before, resets := home.pin.charged, len(home.pin.resets)
	home.pin.allow()
	rebooted.Unlock(t.Context(), []byte("123456"))
	if !rebooted.Unlocked() || home.pin.charged != before+1 || len(home.pin.resets) != resets+1 {
		t.Fatalf("forged mark: unlocked=%v evaluations=%d resets=%d notice=%q", rebooted.Unlocked(), home.pin.charged-before, len(home.pin.resets)-resets, rebooted.View().Notice)
	}
}
