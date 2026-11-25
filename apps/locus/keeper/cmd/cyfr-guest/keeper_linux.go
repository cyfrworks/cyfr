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

	"github.com/cyfr/locus/keeper/internal/vm"
	"golang.org/x/sys/unix"
)

// keeperCaps are the capabilities the keeper keeps, and the only ones it
// starts with (procfs.CheckKeeperCaps): the Locus container's cap_add.
var keeperCaps = map[int]bool{unix.CAP_SETUID: true, unix.CAP_SETGID: true, unix.CAP_KILL: true}

// keeperMain runs in the keeper's group, at the root of a cgroup namespace
// and in a mount namespace of its own, as the first process made them. It
// mounts that namespace's cgroup2 over the guest's, drops every capability
// but the keeper's from its bounding set, and executes the keeper: the
// keeper then holds what it holds in the Locus container, and nothing it
// starts can regain the rest.
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
	if err := dropBounding(); err != nil {
		logf("refusing to start the keeper: %v", err)
		return 1
	}
	if err := unix.Prctl(unix.PR_CAP_AMBIENT, unix.PR_CAP_AMBIENT_CLEAR_ALL, 0, 0, 0); err != nil {
		logf("refusing to start the keeper: clearing the ambient set: %v", err)
		return 1
	}
	argv := []string{vm.GuestKeeper, "serve", "--pool", vm.GuestPoolSpec, "--home-root", vm.GuestHomeRoot,
		"--client-user", vm.GuestClientUser, "--", vm.GuestAgent, "relay"}
	err := syscall.Exec(argv[0], argv, os.Environ())
	logf("refusing to start the keeper: %v", err)
	return 1
}

func dropBounding() error {
	raw, err := os.ReadFile("/proc/sys/kernel/cap_last_cap")
	if err != nil {
		return err
	}
	last, err := strconv.Atoi(strings.TrimSpace(string(raw)))
	if err != nil {
		return err
	}
	for c := 0; c <= last; c++ {
		if keeperCaps[c] {
			continue
		}
		if err := unix.Prctl(unix.PR_CAPBSET_DROP, uintptr(c), 0, 0, 0); err != nil {
			return fmt.Errorf("dropping capability %d from the bounding set: %w", c, err)
		}
	}
	return nil
}
