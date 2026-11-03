// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package shell

import (
	"errors"
	"net/http"
	"os"
	"testing"
)

type reviewPINResetTransport struct {
	next http.RoundTripper
}

func (r reviewPINResetTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	if req.URL.Path == "/device/pin/reset" {
		return nil, errors.New("reset connection unavailable")
	}
	return r.next.RoundTrip(req)
}

func TestReviewS3BFailedResetThenFailedReplacementKeepsSavedPINUsable(t *testing.T) {
	home := newFakeHome(t)
	dir := t.TempDir()
	sh, _ := pinned(t, home, dir)
	sh.Unlock(t.Context(), []byte("123456"))
	sh.cfg.Client.Transport = reviewPINResetTransport{next: http.DefaultTransport}
	sh.SetPIN(t.Context(), []byte("222222"), []byte("222222"))
	saved := record(t, dir).PIN.Evaluator
	sh.Lock("")
	home.pin.allow()
	sh.Unlock(t.Context(), []byte("222222"))
	if err := os.Chmod(dir, 0o500); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(dir, 0o700) })
	sh.SetPIN(t.Context(), []byte("333333"), []byte("333333"))
	if err := os.Chmod(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	if got := record(t, dir).PIN.Evaluator; got != saved {
		t.Fatalf("the failed save changed the record: %s != %s", got, saved)
	}
	sh.Lock("")
	sh.cfg.Client.Transport = http.DefaultTransport
	home.pin.allow()
	sh.Unlock(t.Context(), []byte("222222"))
	if !sh.Unlocked() {
		t.Fatalf("a failed replacement destroyed access to the saved PIN: %s", sh.View().Notice)
	}
}
