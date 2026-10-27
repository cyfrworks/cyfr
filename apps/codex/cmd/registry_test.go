// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"reflect"
	"strings"
	"testing"
)

// The answer registry.sync gives: the namespaces it synced and never a
// token.
const registrySyncAnswer = `{"personal_namespace":"alice","memberships":[{"slug":"acme.com","role":"admin"}],"unsynced":[]}`

// `cyfr registry sync` asks registry.sync and nothing more, and prints the
// namespaces it answered.
func TestRegistrySync_AsksSyncAlone(t *testing.T) {
	onTerminal(t, false)
	srv := newCLIServer(t, "", registrySyncAnswer)

	out, err := runCLI(t, srv, "registry", "sync")
	if err != nil {
		t.Fatalf("cyfr registry sync failed: %v\n%s", err, out)
	}

	if srv.count() != 1 {
		t.Fatalf("expected one request, got %d", srv.count())
	}
	name, args := srv.call(0)
	if want := map[string]any{"action": "sync"}; name != "registry" || !reflect.DeepEqual(args, want) {
		t.Errorf("expected registry %v, got %s %v", want, name, args)
	}
	for _, want := range []string{"alice", "acme.com"} {
		if !strings.Contains(out, want) {
			t.Errorf("the output lacks %q:\n%s", want, out)
		}
	}
}

// The sync's fresh confirmation is met as every confirmed change's is: on a
// terminal the person confirms and the same request is repeated with its id.
func TestRegistrySync_MeetsItsConfirmationOnATerminal(t *testing.T) {
	term := onTerminal(t, true)
	term.enter()
	srv := newCLIServer(t, soon(), pendingSecret, registrySyncAnswer)

	out, err := runCLI(t, srv, "registry", "sync")
	if err != nil {
		t.Fatalf("cyfr registry sync failed: %v\n%s", err, out)
	}

	if got := srv.repeats(); !sameIDs(got, []string{"", pendingSecret}) {
		t.Errorf("the first call carries no id and the repeat its id, got %q", got)
	}
	for i := range 2 {
		if _, args := srv.call(i); !reflect.DeepEqual(args, map[string]any{"action": "sync"}) {
			t.Errorf("request %d asked %v", i, args)
		}
	}
	if !strings.Contains(out, "acme.com") {
		t.Errorf("the output lacks the synced membership:\n%s", out)
	}
}

// `cyfr registry claim <handle>` asks registry.claim_personal for exactly
// that handle.
func TestRegistryClaim_AsksClaimPersonalForTheHandle(t *testing.T) {
	srv := newCLIServer(t, "", `{"handle":"alice","identifier":"alice@cyfr.run"}`)

	out, err := runCLI(t, srv, "registry", "claim", "alice")
	if err != nil {
		t.Fatalf("cyfr registry claim failed: %v\n%s", err, out)
	}

	if srv.count() != 1 {
		t.Fatalf("expected one request, got %d", srv.count())
	}
	name, args := srv.call(0)
	if want := map[string]any{"action": "claim_personal", "handle": "alice"}; name != "registry" || !reflect.DeepEqual(args, want) {
		t.Errorf("expected registry %v, got %s %v", want, name, args)
	}
	if !strings.Contains(out, "alice") {
		t.Errorf("the output lacks the claimed handle:\n%s", out)
	}
}

// The claim takes exactly one handle and sync none; anything else is
// refused before any request.
func TestRegistryClaimAndSync_RefuseOtherArguments(t *testing.T) {
	for _, args := range [][]string{
		{"registry", "claim"},
		{"registry", "claim", "alice", "bob"},
		{"registry", "sync", "alice"},
	} {
		srv := newCLIServer(t, "")
		out, err := runCLI(t, srv, args...)
		if err == nil {
			t.Errorf("cyfr %s was accepted:\n%s", strings.Join(args, " "), out)
		}
		if srv.count() != 0 {
			t.Errorf("cyfr %s sent %d requests", strings.Join(args, " "), srv.count())
		}
	}
}

// The registry's identity-provider probe is gone: there is no
// `cyfr registry probe`.
func TestRegistry_HasNoProbe(t *testing.T) {
	if sub := subcommand(registryCmd, "probe"); sub != nil {
		t.Errorf("`cyfr registry probe` is still registered: %s", sub.Short)
	}
	for _, name := range []string{"claim", "sync"} {
		if subcommand(registryCmd, name) == nil {
			t.Errorf("`cyfr registry %s` is not registered", name)
		}
	}
}
