// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"

	"github.com/cyfr/codex/internal/config"
	"github.com/cyfr/codex/internal/holder"
	"github.com/cyfr/codex/internal/shell"
)

// ownRecord writes this command line's paired record for the home at
// address, as cyfr login --url address leaves one.
func ownRecord(t *testing.T, address string) {
	t.Helper()
	path, err := deviceRecord(address)
	if err != nil {
		t.Fatal(err)
	}
	rec, err := holder.NewSoftware(deviceHome(address), "", "pair", []byte(passphrase))
	if err != nil {
		t.Fatal(err)
	}
	rec.ClientID, rec.Athanor, rec.Certificate = "pcl_1", "ath_1", json.RawMessage(`{"client_id":"pcl_1"}`)
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := rec.Save(path); err != nil {
		t.Fatal(err)
	}
}

var asking = shell.Certification{Audience: "https://hub.example", Athanor: "ath_01a09fee-045b-770b-b745-a62792bb8798",
	ClientID: "pcl_01a09fee-7c1d-7e2f-8a3b-4c5d6e7f8091", DeviceKey: make([]byte, 32)}

// At the person's own CYFR, typed once, this command line's own device
// there is unlocked afresh with its secret, and person.certify is asked
// through that unlock's session for exactly what the asking CYFR
// reserved; its confirmation draws that CYFR's preview here before the
// secret is asked again, and the certificate comes back with that CYFR as
// its issuer. The device is locked once it is done, and no secret reaches
// the home or the output.
func TestCertifyAtHome_UnlocksThereAndConfirmsTheCertification(t *testing.T) {
	withContexts(t, "hub", map[string]*config.Context{"hub": {URL: asking.Audience}})
	cert := `{"certificate":{"issuer":"https://alice.example","client_id":"` + asking.ClientID + `"}}`
	srv := newCLIServer(t, soon(), pendingSecret, cert)
	var auth []string
	var mu sync.Mutex
	inner := srv.Config.Handler
	srv.Config.Handler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		auth = append(auth, r.Header.Get("Authorization"))
		mu.Unlock()
		inner.ServeHTTP(w, r)
	})
	ownRecord(t, srv.URL)
	dev := newFakeDevice(shell.View{Page: shell.PageLocked, Kind: holder.KindSoftware}, func(call string, d *fakeDevice) {
		switch call {
		case "unlock":
			d.set(shell.View{Page: shell.PageUnlocked})
		case "draw":
			d.set(shell.View{Page: shell.PageConfirm, Confirm: &shell.PendingConfirm{Operation: "person.certify",
				Preview: map[string]any{"audience": asking.Audience}}})
		case "decide":
			d.set(shell.View{Page: shell.PageUnlocked, Notice: "Confirmed on this command line."})
		}
	})
	var opened []deviceOptions
	previous := openDevice
	openDevice = func(o deviceOptions) (device, error) { opened = append(opened, o); return dev, nil }
	t.Cleanup(func() { openDevice = previous })

	c, out := typed(srv.URL, passphrase, passphrase)
	got, err := certifyAtHome(c)(t.Context(), asking)
	if err != nil {
		t.Fatalf("certify: %v\n%s", err, out)
	}
	if got.Issuer != deviceHome(srv.URL) || !strings.Contains(string(got.Certificate), asking.ClientID) {
		t.Fatalf("certified %+v", got)
	}
	if !slices.Equal(dev.calls, []string{"unlock", "session", "draw", "decide"}) || string(dev.secrets["unlock"]) != passphrase ||
		string(dev.secrets["decide"]) != passphrase || dev.locks != 2 {
		t.Fatalf("calls %v, locks %d", dev.calls, dev.locks)
	}
	if len(opened) != 2 || opened[0].address != srv.URL || opened[1].session != "TOKEN-1" || opened[0].certify != nil {
		t.Fatalf("opened %+v", opened)
	}
	want := map[string]any{"action": "certify", "device_key": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
		"audience": asking.Audience, "athanor": asking.Athanor, "client_id": asking.ClientID}
	for i := range 2 {
		args := srv.arguments(i)
		if name, _ := srv.call(i); name != "person" || len(args) != len(want) {
			t.Fatalf("request %d: %s %v", i, name, args)
		}
		for k, v := range want {
			if args[k] != v {
				t.Errorf("request %d: %s = %v, want %v", i, k, args[k], v)
			}
		}
	}
	if !slices.Equal(auth, []string{"Bearer TOKEN-1", "Bearer TOKEN-1"}) {
		t.Errorf("the home was asked with %q", auth)
	}
	printed := out.String()
	if strings.Contains(printed, passphrase) || strings.Index(printed, asking.Audience) < 0 ||
		strings.Index(printed, "person.certify") > strings.LastIndex(printed, "PIN or passphrase") {
		t.Errorf("the output:\n%s", printed)
	}
}

// A CYFR where this command line is not a device yet is told to pair it
// there first, and nothing is opened or asked; the asking CYFR's own
// address and something that is not an address are refused; Enter alone
// takes the CYFR that certified this command line before.
func TestCertifyAtHome_RefusesWhereThisCommandLineIsNoDevice(t *testing.T) {
	withContexts(t, "hub", map[string]*config.Context{"hub": {URL: asking.Audience}})
	opened := 0
	previous := openDevice
	openDevice = func(o deviceOptions) (device, error) { opened++; return nil, os.ErrNotExist }
	t.Cleanup(func() { openDevice = previous })

	for typedHome, want := range map[string]string{
		"https://alice.example": "Pair it there first with cyfr login --url https://alice.example",
		"https://hub.example/":  "is the CYFR asking",
		"alice.example":         "is not a CYFR's address",
	} {
		c, _ := typed(typedHome)
		if _, err := certifyAtHome(c)(t.Context(), asking); err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("%s: %v, want %q", typedHome, err, want)
		}
	}
	again := asking
	again.Issuer = "https://alice.example"
	c, out := typed("")
	if _, err := certifyAtHome(c)(t.Context(), again); err == nil || !strings.Contains(err.Error(), "--url https://alice.example") ||
		!strings.Contains(out.String(), "Enter for https://alice.example") {
		t.Errorf("the offered address: %v\n%s", err, out)
	}
	if opened != 0 {
		t.Errorf("a device was opened %d times", opened)
	}
}
