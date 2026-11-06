// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package shell

import (
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
)

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
