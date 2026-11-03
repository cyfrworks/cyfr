// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"

	"github.com/cyfr/codex/internal/holder"
	"github.com/cyfr/codex/internal/shell"
)

func TestReviewS3BLoginOffersRecoveryForSuspendedPIN(t *testing.T) {
	var evaluations, recovery atomic.Int32
	home := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/device/pin/evaluate":
			evaluations.Add(1)
			w.WriteHeader(http.StatusNotFound)
			w.Write([]byte(`{"error":"not_found"}`))
		case "/restore/kit/challenge":
			recovery.Add(1)
			w.WriteHeader(http.StatusServiceUnavailable)
			w.Write([]byte(`{"error":"unavailable"}`))
		default:
			t.Errorf("unexpected entry %s", r.URL.Path)
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(home.Close)
	path := filepath.Join(t.TempDir(), "device.json")
	rec := &holder.Record{Version: 1, Kind: holder.KindSoftware, Home: home.URL,
		PublicKey: bytes.Repeat([]byte{1}, 32), ClientID: "pcl_test", Athanor: "ath_test",
		Certificate: json.RawMessage(`{}`),
		PIN:         &holder.PINBlob{Evaluator: "pev_test", Salt: make([]byte, 16), Nonce: make([]byte, 12)}}
	if err := rec.Save(path); err != nil {
		t.Fatal(err)
	}
	sh, err := shell.New(shell.Config{Address: home.URL, Client: home.Client(), Record: path,
		Noun: "command line", Chip: func() bool { return false }})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { sh.Lock("") })
	raw, err := os.ReadFile("../../../tests/fixtures/recovery_code.json")
	if err != nil {
		t.Fatal(err)
	}
	var vectors struct{ Valid []struct{ Code string } }
	if err := json.Unmarshal(raw, &vectors); err != nil {
		t.Fatal(err)
	}
	c, out := typed("123456", vectors.Valid[0].Code, "123456")
	d := &loginDriver{sh: &sessionDevice{Shell: sh}, c: c, mode: "pair", home: home.URL}
	err = d.run(t.Context())
	if recovery.Load() != 1 {
		t.Fatalf("suspended PIN login never offered recovery: evaluations=%d recovery=%d kit=%v err=%v output=%q",
			evaluations.Load(), recovery.Load(), sh.View().Kit, err, out.String())
	}
}
