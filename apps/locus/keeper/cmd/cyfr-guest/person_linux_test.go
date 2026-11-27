// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package main

import (
	"net/netip"
	"reflect"
	"strings"
	"testing"

	"github.com/cyfr/locus/keeper/internal/vm"
)

// A person's VM's address and gateway are read from the kernel's command
// line in their one form; a line naming none is a machine with no card,
// and one naming them in any other form refuses the guest's start.
func TestTheGuestReadsItsAddressFromItsCommandLine(t *testing.T) {
	n, ok, err := netOf("quiet reboot=k cyfr.net=10.213.0.6,10.213.0.5 init=/usr/local/bin/cyfr-guest")
	if err != nil || !ok || n.Inner != netip.MustParseAddr("10.213.0.6") || n.Gateway != netip.MustParseAddr("10.213.0.5") {
		t.Fatalf("%+v %t %v", n, ok, err)
	}
	if _, ok, err := netOf("quiet reboot=k init=/usr/local/bin/cyfr-guest"); ok || err != nil {
		t.Fatalf("a line naming no card answered %t %v", ok, err)
	}
	for _, bad := range []string{"cyfr.net=10.213.0.6", "cyfr.net=10.213.0.6,", "cyfr.net=fd00::2,fd00::1", "cyfr.net=10.213.000.6,10.213.0.5", "cyfr.net=host,10.213.0.5"} {
		if _, _, err := netOf(bad); err == nil {
			t.Errorf("%q was taken", bad)
		}
	}
}

// guest-check's keeper serves one relay role with no kept homes, as
// before; a person's keeps their homes on their disk, its pool routed.
func TestAPersonsKeeperKeepsTheirHomesOnTheirDisk(t *testing.T) {
	check := keeperArgs(false)
	if want := []string{vm.GuestKeeper, "serve", "--role", vm.GuestRoleSpec, "--pool", vm.GuestPoolSpec, "--home-root", vm.GuestHomeRoot,
		"--guard", vm.GuestGuardControl, "--", vm.GuestAgent, "relay"}; !reflect.DeepEqual(check, want) {
		t.Fatalf("guest-check's keeper: %v", check)
	}
	person := strings.Join(keeperArgs(true), " ")
	for _, want := range []string{"--role backends:10013:4101:backends:kept", "--pool backends:20001-20032:routed", "--kept-homes /var/lib/locus/kept:40001-49999",
		"--resolver 169.254.0.53:53 --"} {
		if !strings.Contains(person, want) {
			t.Errorf("a person's keeper lacks %q: %s", want, person)
		}
	}
	if strings.Contains(strings.Join(guardEnv(false), " "), "CYFR_GUARD_RESOLVER") {
		t.Error("guest-check's guard is given a resolver")
	}
	if env := strings.Join(guardEnv(true), " "); !strings.Contains(env, "CYFR_GUARD_RESOLVER=169.254.0.53:53") {
		t.Errorf("a person's guard asks no names of the host's: %s", env)
	}
}
