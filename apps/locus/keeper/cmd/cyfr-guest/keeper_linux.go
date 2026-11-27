// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package main

import (
	"fmt"
	"os"
	"runtime"
	"strconv"
	"strings"
	"syscall"

	"github.com/cyfr/locus/keeper/internal/outer"
	"github.com/cyfr/locus/keeper/internal/vm"
	"golang.org/x/sys/unix"
)

// keeperCaps are the capabilities the keeper keeps, and the only ones it
// starts with (procfs.CheckKeeperCaps): the Locus container's cap_add.
var keeperCaps = map[int]bool{unix.CAP_SETUID: true, unix.CAP_SETGID: true, unix.CAP_KILL: true}

// keeperCapNames are keeperCaps as the seccomp profile names them, which
// decide its rules' includes and excludes as Docker decides them for the
// Locus container.
var keeperCapNames = []string{"CAP_SETUID", "CAP_SETGID", "CAP_KILL"}

// keeperMain runs in the keeper's group, at the root of a cgroup namespace
// and in a mount namespace of its own, as the first process made them. It
// mounts that namespace's cgroup2 over the guest's, drops every capability
// but the keeper's from its bounding set, installs the keeper's own
// system-call policy, the Locus container's seccomp profile compiled for
// the guest kernel's table and the keeper's capabilities (package outer),
// and executes the keeper: the keeper then holds what it holds in the Locus
// container, under the same outer policy, beneath each space's own filter,
// and nothing it starts can regain the rest or lift either.
func keeperMain() int {
	// The bounding and ambient sets are a thread's: they are changed on the
	// thread that executes the keeper.
	runtime.LockOSThread()
	// The guest's own cgroup2 mount is this namespace's copy: it goes, and
	// a mount made from inside the cgroup namespace shows its root.
	if err := unix.Unmount("/sys/fs/cgroup", unix.MNT_DETACH); err != nil {
		logf("refusing to start the keeper: unmounting the guest's cgroup tree: %v", err)
		return 1
	}
	if err := unix.Mount("cgroup2", "/sys/fs/cgroup", "cgroup2", unix.MS_NOSUID|unix.MS_NODEV|unix.MS_NOEXEC, "nsdelegate"); err != nil {
		logf("refusing to start the keeper: mounting its cgroup namespace: %v", err)
		return 1
	}
	if err := dropBounding(keeperCaps); err != nil {
		logf("refusing to start the keeper: %v", err)
		return 1
	}
	if err := unix.Prctl(unix.PR_CAP_AMBIENT, unix.PR_CAP_AMBIENT_CLEAR_ALL, 0, 0, 0); err != nil {
		logf("refusing to start the keeper: clearing the ambient set: %v", err)
		return 1
	}
	// Installed while this process still holds SYS_ADMIN in its effective
	// set, so it needs no no_new_privs, which the keeper's stage would carry.
	policy, err := outer.Load(vm.GuestPolicy, vm.GuestSyscalls, keeperCapNames)
	if err != nil {
		logf("refusing to start the keeper: its system-call policy: %v", err)
		return 1
	}
	if err := outer.Install(policy); err != nil {
		logf("refusing to start the keeper: installing its system-call policy: %v", err)
		return 1
	}
	argv := []string{vm.GuestKeeper, "serve", "--role", vm.GuestRoleSpec, "--pool", vm.GuestPoolSpec,
		"--home-root", vm.GuestHomeRoot, "--guard", vm.GuestGuardControl, "--", vm.GuestAgent, "relay"}
	err = syscall.Exec(argv[0], argv, os.Environ())
	logf("refusing to start the keeper: %v", err)
	return 1
}

// guardMain is the guard's start: every capability but NET_ADMIN dropped
// from the bounding set, as compose's guard holds NET_ADMIN alone, then the
// image's guard, `cyfr-locus guard-control`.
func guardMain() int {
	runtime.LockOSThread()
	if err := dropBounding(map[int]bool{unix.CAP_NET_ADMIN: true}); err != nil {
		logf("refusing to start the guard: %v", err)
		return 1
	}
	if err := unix.Prctl(unix.PR_CAP_AMBIENT, unix.PR_CAP_AMBIENT_CLEAR_ALL, 0, 0, 0); err != nil {
		logf("refusing to start the guard: clearing the ambient set: %v", err)
		return 1
	}
	err := syscall.Exec(vm.GuestKeeper, []string{vm.GuestKeeper, "guard-control"}, os.Environ())
	logf("refusing to start the guard: %v", err)
	return 1
}

func dropBounding(keep map[int]bool) error {
	raw, err := os.ReadFile("/proc/sys/kernel/cap_last_cap")
	if err != nil {
		return err
	}
	last, err := strconv.Atoi(strings.TrimSpace(string(raw)))
	if err != nil {
		return err
	}
	for c := 0; c <= last; c++ {
		if keep[c] {
			continue
		}
		if err := unix.Prctl(unix.PR_CAPBSET_DROP, uintptr(c), 0, 0, 0); err != nil {
			return fmt.Errorf("dropping capability %d from the bounding set: %w", c, err)
		}
	}
	return nil
}
