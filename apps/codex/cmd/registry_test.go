// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"reflect"
	"testing"
)

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

	srv := newCLIServer(t, "")
	if out, _ := runCLI(t, srv, "registry", "claim", "alice"); srv.count() != 0 {
		t.Errorf("cyfr registry claim alice sent %d requests:\n%s", srv.count(), out)
	}
}

// `cyfr registry discover <namespace>` asks component.discover for that
// publisher's namespace alone.
func TestRegistryDiscover_AsksByNamespace(t *testing.T) {
	srv := newCLIServer(t, "", `{"components":[],"total":0}`)

	out, err := runCLI(t, srv, "registry", "discover", "alice")
	if err != nil {
		t.Fatalf("cyfr registry discover failed: %v\n%s", err, out)
	}

	want := map[string]any{"action": "discover", "namespace": "alice"}
	if name, args := srv.call(0); name != "component" || !reflect.DeepEqual(args, want) {
		t.Errorf("expected component %v, got %s %v", want, name, args)
	}
}
