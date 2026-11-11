// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package account_test

import (
	"context"
	"crypto/ed25519"
	"errors"
	"strings"
	"testing"

	"github.com/cyfr/codex/internal/account"
	"github.com/cyfr/codex/internal/account/accounttest"
)

func now() int64 { return 1790000000000 }

func newDevice(t *testing.T) ed25519.PrivateKey {
	_, priv, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	return priv
}

func config(t *testing.T, svc *accounttest.Service) account.Config {
	c, err := account.Directory{URL: svc.URL()}.Config(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	return c
}

// An account made from a device: the genesis and the device's add_key
// signed by the recovery key the code's secret derives, the policy
// accepted before the claim, and the name the account's; the log lists the
// device and the recovery key, and the code reads back to the account.
func TestSubmit_MakesTheAccountWithThisDeviceAndItsName(t *testing.T) {
	svc := accounttest.New(t)
	svc.Policy = &account.Policy{Version: "2026-10", URL: "https://cyfr.run/terms"}
	dev := newDevice(t)
	a, secret, key, err := account.Begin(config(t, svc), "mira", "2026-10", dev.Public().(ed25519.PublicKey), now())
	if err != nil {
		t.Fatal(err)
	}
	code, _ := account.EncodeRecoveryCode(a.Identifier, secret)
	if id, back, err := account.DecodeRecoveryCode(code); err != nil || id != a.Identifier || string(back) != string(secret) {
		t.Fatalf("the code reads back to %s, %v", id, err)
	}
	var saved []string
	err = account.Submit(context.Background(), &a, key, now, nil, func(a account.Attempt) error {
		saved = append(saved, a.Step)
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	st := svc.State(t, a.Identifier)
	if _, listed := st.Key(account.Kid(dev.Public().(ed25519.PublicKey))); !listed || len(st.Keys) != 1 {
		t.Fatalf("the log lists %+v", st.Keys)
	}
	if account.RecoverySigner(st.Recovery[0]) != account.RecoverySigner(account.RecoveryKey(secret).Public().(ed25519.PublicKey)) {
		t.Fatal("the recovery set is not the code's key")
	}
	if svc.Holder("mira") != a.Identifier || svc.Accepted(a.Identifier) != "2026-10" {
		t.Fatalf("the name is %s's, the policy %q", svc.Holder("mira"), svc.Accepted(a.Identifier))
	}
	if a.Step != account.StepDone || strings.Join(saved, " ") != "append name name done" {
		t.Fatalf("steps saved %v, at %s", saved, a.Step)
	}
}

// A lost answer to each write is sent again with the same bytes, which the
// directory answers exists, and a claim whose answer was lost is
// reconciled by reading the name: the account's is done, nothing claimed
// twice.
func TestSubmit_LostAnswersLandOnce(t *testing.T) {
	svc := accounttest.New(t)
	dev := newDevice(t)
	a, _, key, _ := account.Begin(config(t, svc), "mira", "", dev.Public().(ed25519.PublicKey), now())
	save := func(account.Attempt) error { return nil }
	for range 3 {
		svc.Lose = 1
		err := account.Submit(context.Background(), &a, key, now, nil, save)
		if !errors.Is(err, account.ErrUnreachable) {
			t.Fatalf("a lost answer is %v", err)
		}
	}
	if err := account.Submit(context.Background(), &a, key, now, nil, save); err != nil {
		t.Fatal(err)
	}
	if len(svc.Log(a.Identifier)) != 2 || svc.Holder("mira") != a.Identifier || svc.Writes != 3 {
		t.Fatalf("log %d entries, name %s, %d writes", len(svc.Log(a.Identifier)), svc.Holder("mira"), svc.Writes)
	}
}

// A name someone took meanwhile is ErrNameTaken and claims nothing; the
// account stands, and another name is claimed for it.
func TestSubmit_ATakenNameAsksAnother(t *testing.T) {
	svc := accounttest.New(t)
	dev := newDevice(t)
	a, _, key, _ := account.Begin(config(t, svc), "mira", "", dev.Public().(ed25519.PublicKey), now())
	svc.Hold("mira", "per_"+strings.Repeat("0", 64))
	save := func(account.Attempt) error { return nil }
	if err := account.Submit(context.Background(), &a, key, now, nil, save); !errors.Is(err, account.ErrNameTaken) {
		t.Fatalf("a taken name is %v", err)
	}
	a.Name = "mira2"
	if err := account.Submit(context.Background(), &a, key, now, nil, save); err != nil || svc.Holder("mira2") != a.Identifier {
		t.Fatalf("another name: %v", err)
	}
	if err := account.CheckName(context.Background(), account.Registry{Origin: svc.URL()}, "mira2"); !errors.Is(err, account.ErrNameTaken) {
		t.Fatalf("CheckName of a held name is %v", err)
	}
	if err := account.CheckName(context.Background(), account.Registry{Origin: svc.URL()}, "free"); err != nil {
		t.Fatalf("CheckName of a free name is %v", err)
	}
}

// A reserved name is found by no lookup, so it reads as free, and its
// claim is ErrNameReserved; the account stands, and another name is
// claimed for it.
func TestSubmit_AReservedNameAsksAnother(t *testing.T) {
	svc := accounttest.New(t)
	dev := newDevice(t)
	if err := account.CheckName(context.Background(), account.Registry{Origin: svc.URL()}, accounttest.Reserved); err != nil {
		t.Fatalf("CheckName of the reserved name is %v", err)
	}
	a, _, key, _ := account.Begin(config(t, svc), accounttest.Reserved, "", dev.Public().(ed25519.PublicKey), now())
	save := func(account.Attempt) error { return nil }
	if err := account.Submit(context.Background(), &a, key, now, nil, save); !errors.Is(err, account.ErrNameReserved) {
		t.Fatalf("a reserved name is %v", err)
	}
	a.Name = "mira"
	if err := account.Submit(context.Background(), &a, key, now, nil, save); err != nil || svc.Holder("mira") != a.Identifier || len(svc.Log(a.Identifier)) != 2 {
		t.Fatalf("another name: %v", err)
	}
}

// A registry that asks for a newer policy than the one accepted is
// ErrPolicyChanged.
func TestSubmit_ANewerPolicyIsAskedAgain(t *testing.T) {
	svc := accounttest.New(t)
	svc.Policy = &account.Policy{Version: "v1", URL: "https://cyfr.run/terms"}
	dev := newDevice(t)
	a, _, key, _ := account.Begin(config(t, svc), "mira", "v1", dev.Public().(ed25519.PublicKey), now())
	svc.Policy = &account.Policy{Version: "v2", URL: "https://cyfr.run/terms"}
	err := account.Submit(context.Background(), &a, key, now, nil, func(account.Attempt) error { return nil })
	if !errors.Is(err, account.ErrPolicyChanged) || svc.Holder("mira") != "" {
		t.Fatalf("a newer policy is %v", err)
	}
}

// A terminal's key adds another device's key to its account: add_key
// after the head, signed by the terminal's key; a key listed already is
// ErrListed, and a signer the log does not list adds nothing.
func TestApprove_AddsTheKeyByThisDevicesSignature(t *testing.T) {
	svc := accounttest.New(t)
	dev := newDevice(t)
	devPub := dev.Public().(ed25519.PublicKey)
	a, _, key, _ := account.Begin(config(t, svc), "mira", "", devPub, now())
	if err := account.Submit(context.Background(), &a, key, now, nil, func(account.Attempt) error { return nil }); err != nil {
		t.Fatal(err)
	}
	other := newDevice(t).Public().(ed25519.PublicKey)
	d := account.Directory{URL: a.Directory}
	sign := func(m []byte) []byte { return ed25519.Sign(dev, m) }
	svc.Lose = 1
	if err := account.Approve(context.Background(), d, a.Identifier, devPub, sign, other, now()); err != nil {
		t.Fatal(err)
	}
	st := svc.State(t, a.Identifier)
	if _, listed := st.Key(account.Kid(other)); !listed || len(svc.Log(a.Identifier)) != 3 {
		t.Fatalf("the log lists %d keys in %d entries", len(st.Keys), len(svc.Log(a.Identifier)))
	}
	if err := account.Approve(context.Background(), d, a.Identifier, devPub, sign, other, now()); !errors.Is(err, account.ErrListed) {
		t.Fatalf("a listed key is %v", err)
	}
	stranger := newDevice(t)
	err := account.Approve(context.Background(), d, a.Identifier, stranger.Public().(ed25519.PublicKey),
		func(m []byte) []byte { return ed25519.Sign(stranger, m) }, newDevice(t).Public().(ed25519.PublicKey), now())
	if !errors.Is(err, account.ErrNotListed) {
		t.Fatalf("an unlisted signer is %v", err)
	}
}
