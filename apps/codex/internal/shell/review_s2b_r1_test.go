// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package shell

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"
)

func TestReviewRemoteRenewalRejectsAnotherPerson(t *testing.T) {
	issuer := newIssuerHome(t)
	b := Binding{Home: "https://hub.example", Athanor: "ath_01a09fee-045b-770b-b745-a62792bb8798", ClientID: "pcl_01a09fee-7c1d-7e2f-8a3b-4c5d6e7f8091", DeviceKey: testKey(t).pub}
	now := time.Now().UnixMilli()
	cert, _ := json.Marshal(map[string]any{"protocol": "cyfr-device-cert/v1", "athanor": b.Athanor, "client_id": b.ClientID, "device_key": b64(b.DeviceKey), "audience": b.Home, "issuer": issuer.address(), "not_before": now - 3_000_000, "expires_at": now + 600_000, "subject": map[string]any{"kind": "identity", "identifier": "per_" + strings.Repeat("a", 64), "key_epoch": "sha256:" + strings.Repeat("a", 64)}})
	if _, err := RenewAtIssuer(t.Context(), issuer.srv.Client(), b, cert, testKey(t)); err != nil {
		t.Fatalf("unchanged person refused: %v", err)
	}
	issuer.replacement = func(c map[string]any) map[string]any {
		c["subject"] = map[string]any{"kind": "identity", "identifier": "per_" + strings.Repeat("b", 64), "key_epoch": "sha256:" + strings.Repeat("a", 64)}
		return c
	}
	if got, err := RenewAtIssuer(t.Context(), issuer.srv.Client(), b, cert, testKey(t)); !errors.Is(err, ErrRefused) {
		t.Fatalf("another person's renewal accepted: err=%v, certificate=%s", err, got)
	}
}
