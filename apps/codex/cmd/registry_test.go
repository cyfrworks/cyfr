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
const registrySyncAnswer = `{"personal_namespace":"alice","memberships":[{"slug":"acme.com","role":"admin"}]}`

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
