// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package main

import (
	"errors"
	"fmt"
	"io/fs"
	"net/netip"
	"os"
	"strings"

	"golang.org/x/sys/unix"

	"github.com/cyfr/locus/keeper/guard"
	"github.com/cyfr/locus/keeper/internal/vm"
)

// A person's VM is told so by what its host attached: their disk, the
// second drive (vm.GuestDisk), and their card, whose address the kernel's
// command line names (vm.NetArg). The first process mounts the disk as the
// guest keeper's kept homes' root and sets the card up before the guard
// starts, so the guard reads its island from it and asks its names of the
// host's guard; its keeper's one role then keeps the person's homes on that
// disk. A guest with neither is guest-check's; one with one alone is a host
// that attached half a person, and the guest does not start.

// netOf is the address and gateway cmdline's vm.NetArg names, and whether
// it names them: <inner>,<gateway>, two IPv4 addresses (netip takes each in
// its one form alone).
func netOf(cmdline string) (vm.Network, bool, error) {
	for _, arg := range strings.Fields(cmdline) {
		value, ok := strings.CutPrefix(arg, vm.NetArg+"=")
		if !ok {
			continue
		}
		in, gw, ok := strings.Cut(value, ",")
		inner, ierr := netip.ParseAddr(in)
		gateway, gerr := netip.ParseAddr(gw)
		if !ok || ierr != nil || gerr != nil || !inner.Is4() || !gateway.Is4() {
			return vm.Network{}, false, fmt.Errorf("%s is %q, not <inner>,<gateway>", vm.NetArg, value)
		}
		return vm.Network{Inner: inner, Gateway: gateway}, true, nil
	}
	return vm.Network{}, false, nil
}

// personOf reads what the host attached: the card's address on the kernel's
// command line and the disk's device, both or neither.
func personOf() (vm.Network, bool, error) {
	cmdline, err := os.ReadFile("/proc/cmdline")
	if err != nil {
		return vm.Network{}, false, err
	}
	n, card, err := netOf(string(cmdline))
	if err != nil {
		return vm.Network{}, false, err
	}
	_, derr := os.Stat(vm.GuestDisk)
	disk := derr == nil
	if derr != nil && !errors.Is(derr, fs.ErrNotExist) {
		return vm.Network{}, false, derr
	}
	if card != disk {
		return vm.Network{}, false, fmt.Errorf("the host attached a card (%t) and a disk (%t): a person's VM has both, guest-check's neither", card, disk)
	}
	return n, card, nil
}

// startPerson mounts the person's disk at vm.GuestKeptRoot, the guest
// keeper's kept homes' root, root's with home.KeptRootMode's bits, and sets
// the card up (guard.GuestLink).
func startPerson(n vm.Network) error {
	if err := unix.Mount(vm.GuestDisk, vm.GuestKeptRoot, "ext4", unix.MS_NOSUID|unix.MS_NODEV, ""); err != nil {
		return fmt.Errorf("mounting the person's disk %s at %s: %w", vm.GuestDisk, vm.GuestKeptRoot, err)
	}
	if err := os.Chown(vm.GuestKeptRoot, 0, 0); err != nil {
		return err
	}
	if err := os.Chmod(vm.GuestKeptRoot, os.ModeSticky|0o773); err != nil {
		return err
	}
	if err := guard.GuestLink(n.Inner, n.Gateway); err != nil {
		return fmt.Errorf("the person's card: %w", err)
	}
	return nil
}

// keeperArgs are the guest keeper's command line: a person's VM's keeps the
// person's homes on their disk, its pool routed by the guest's guard.
func keeperArgs(person bool) []string {
	role, pool := vm.GuestRoleSpec, vm.GuestPoolSpec
	argv := []string{vm.GuestKeeper, "serve"}
	if person {
		role, pool = vm.GuestPersonRoleSpec, vm.GuestPersonPoolSpec
	}
	argv = append(argv, "--role", role, "--pool", pool, "--home-root", vm.GuestHomeRoot)
	if person {
		argv = append(argv, "--kept-homes", vm.GuestKeptRoot+":"+vm.GuestKeptUIDs)
	}
	return append(argv, "--guard", vm.GuestGuardControl, "--", vm.GuestAgent, "relay")
}

// guardEnv is the guest guard's environment: a person's VM's asks its
// routes' names of the host's guard.
func guardEnv(person bool) []string {
	env := []string{path, "CYFR_GUARD_CONTROL=" + vm.GuestGuardControl, "CYFR_GUARD_CONTROL_PLANE=192.0.2.1",
		"CYFR_PRIVATE_EGRESS_TARGETS="}
	if person {
		env = append(env, "CYFR_GUARD_RESOLVER="+netip.AddrPortFrom(guard.MachineNames, 53).String())
	}
	return env
}
