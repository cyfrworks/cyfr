// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"context"
	"encoding/json"
	"reflect"
	"strings"
	"testing"
)

// The answer registry.sync gives: the namespaces it synced and never a
// token.
const registrySyncAnswer = `{"personal_namespace":"alice","memberships":[{"slug":"acme.com","role":"admin"}]}`

// registrySyncAsked is registry.sync's first answer to a login shell's
// session, as the server gives it: the request to sign and the account
// page that would sign it with a passkey.
func registrySyncAsked(t *testing.T) string {
	t.Helper()
	asked, _ := registryAsked(t)
	raw, err := json.Marshal(map[string]any{"request": asked, "url": "https://cyfr.run/account/sign#request"})
	if err != nil {
		t.Fatal(err)
	}
	return string(raw)
}

// `cyfr registry sync` asks registry.sync, signs the request it answers
// and asks again with the signed request, then prints the namespaces it
// answered.
func TestRegistrySync_SignsTheRequestAndAsksAgain(t *testing.T) {
	saved := registrySigner
	t.Cleanup(func() { registrySigner = saved })
	registrySigner = func(context.Context, string, any) (any, error) {
		return map[string]any{"signed": true}, nil
	}
	srv := newCLIServer(t, "", registrySyncAsked(t), registrySyncAnswer)

	out, err := runCLI(t, srv, "registry", "sync")
	if err != nil {
		t.Fatalf("cyfr registry sync failed: %v\n%s", err, out)
	}

	if srv.count() != 2 {
		t.Fatalf("expected two requests, got %d", srv.count())
	}
	for i, want := range []map[string]any{
		{"action": "sync"},
		{"action": "sync", "answer": map[string]any{"signed": true}},
	} {
		if name, args := srv.call(i); name != "registry" || !reflect.DeepEqual(args, want) {
			t.Errorf("request %d: expected registry %v, got %s %v", i, want, name, args)
		}
	}
	for _, want := range []string{"alice", "acme.com"} {
		if !strings.Contains(out, want) {
			t.Errorf("the output lacks %q:\n%s", want, out)
		}
	}
}

// Off a terminal the signature cannot be asked: sync says so and asks
// nothing more than its first request.
func TestRegistrySync_OffATerminalSaysTheSignatureIsAskedAtOne(t *testing.T) {
	savedTerminal := askTerminal
	t.Cleanup(func() { askTerminal = savedTerminal })
	askTerminal = func() bool { return false }
	srv := newCLIServer(t, "", registrySyncAsked(t), registrySyncAnswer)

	out, err := runCLI(t, srv, "registry", "sync")
	if err == nil || !strings.Contains(err.Error()+out, "at a terminal with its PIN or passphrase") {
		t.Fatalf("cyfr registry sync off a terminal: %v\n%s", err, out)
	}
	if srv.count() != 1 {
		t.Errorf("expected one request, got %d", srv.count())
	}
}

// Sync takes no argument; one is refused before any request.
func TestRegistrySync_RefusesAnArgument(t *testing.T) {
	srv := newCLIServer(t, "")
	out, err := runCLI(t, srv, "registry", "sync", "alice")
	if err == nil {
		t.Errorf("cyfr registry sync alice was accepted:\n%s", out)
	}
	if srv.count() != 0 {
		t.Errorf("cyfr registry sync alice sent %d requests", srv.count())
	}
}

// The registry's identity-provider probe and the personal claim are gone:
// there is no `cyfr registry probe` and no `cyfr registry claim`, since a
// person's name is taken at cyfr.run when CYFR makes them, and `cyfr
// registry claim alice` sends nothing.
func TestRegistry_HasNoProbeAndNoClaim(t *testing.T) {
	for _, name := range []string{"probe", "claim"} {
		if sub := subcommand(registryCmd, name); sub != nil {
			t.Errorf("`cyfr registry %s` is still registered: %s", name, sub.Short)
		}
	}
	if subcommand(registryCmd, "sync") == nil {
		t.Error("`cyfr registry sync` is not registered")
	}

	srv := newCLIServer(t, "")
	if out, _ := runCLI(t, srv, "registry", "claim", "alice"); srv.count() != 0 {
		t.Errorf("cyfr registry claim alice sent %d requests:\n%s", srv.count(), out)
	}
}
