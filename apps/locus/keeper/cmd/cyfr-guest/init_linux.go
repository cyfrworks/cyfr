// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"

	"github.com/cyfr/locus/keeper/internal/vm"
	"golang.org/x/sys/unix"
)

// keeperGroup is the keeper's group, under the guest's root group, and the
// root of the keeper's cgroup namespace: the place the Locus container's
// own group has in a host's.
const keeperGroup = "/sys/fs/cgroup/locus"

// guestReserve is the guest's memory kept outside the keeper's group: what
// the kernel counts as the guest's but neither the keeper nor a space may
// take, so no space's growth ends the agent, whose end is the machine's.
const guestReserve = 64 << 20

// initMain is the guest's first process. It makes the guest's mounts and
// the keeper's group, starts the keeper, reaps every orphan, and ends the
// machine when the keeper ends: the keeper ends when its client, the
// agent's relay, does, which is when the host's control connection does.
// It returns only when it cannot go on, which ends the machine too
// (panic=-1, vm's boot arguments).
func initMain() int {
	if err := mounts(); err != nil {
		logf("refusing to start: %v", err)
		return 1
	}
	group, err := keeperCgroup()
	if err != nil {
		logf("refusing to start: %v", err)
		return 1
	}
	self, err := os.Executable()
	if err != nil {
		logf("refusing to start: %v", err)
		return 1
	}
	cmd := exec.Command(self, "keeper")
	cmd.Env = []string{"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"}
	cmd.Stdout, cmd.Stderr = os.Stderr, os.Stderr
	// Born in the keeper's group, then a cgroup namespace rooted there and a
	// mount namespace of its own, where the keeper step mounts that
	// namespace's cgroup2: the keeper sees its group as the root, as it
	// does in the Locus container.
	cmd.SysProcAttr = &syscall.SysProcAttr{
		UseCgroupFD:  true,
		CgroupFD:     int(group.Fd()),
		Unshareflags: unix.CLONE_NEWCGROUP | unix.CLONE_NEWNS,
	}
	if err := cmd.Start(); err != nil {
		logf("refusing to start: the keeper: %v", err)
		return 1
	}
	_ = group.Close()
	keeper := cmd.Process.Pid
	for {
		var ws unix.WaitStatus
		pid, err := unix.Wait4(-1, &ws, 0, nil)
		if errors.Is(err, unix.EINTR) {
			continue
		}
		if err != nil {
			logf("waiting: %v", err)
			break
		}
		if pid == keeper {
			logf("the keeper ended (%s): the machine ends", describe(ws))
			break
		}
	}
	unix.Sync()
	// A reset, not a power-off: Firecracker ends its process when the guest
	// resets it through the keyboard controller (reboot=k).
	if err := unix.Reboot(unix.LINUX_REBOOT_CMD_RESTART); err != nil {
		logf("ending the machine: %v", err)
	}
	return 1
}

func describe(ws unix.WaitStatus) string {
	if ws.Signaled() {
		return "signal " + ws.Signal().String()
	}
	return "exit " + strconv.Itoa(ws.ExitStatus())
}

// mounts are the guest's own filesystems over its read-only root, the
// image's programs. They are the Locus container's, so the keeper finds
// what it finds there: a /proc, /sys and /dev of the guest's own, the
// POSIX message queues the keeper's residue check reads, the cgroup2 tree,
// a /run with the client's 0700 folder, and the home root, mode 1733. There
// is no writable /tmp or /dev/shm, which the keeper refuses.
func mounts() error {
	type m struct {
		source, target, fstype string
		flags                  uintptr
		data                   string
	}
	const hidden = unix.MS_NOSUID | unix.MS_NODEV | unix.MS_NOEXEC
	for _, mt := range []m{
		{"proc", "/proc", "proc", hidden, ""},
		{"sysfs", "/sys", "sysfs", hidden, ""},
		{"devtmpfs", "/dev", "devtmpfs", unix.MS_NOSUID, "mode=0755"},
		{"devpts", "/dev/pts", "devpts", unix.MS_NOSUID | unix.MS_NOEXEC, "newinstance,ptmxmode=0666,mode=0620"},
		{"mqueue", "/dev/mqueue", "mqueue", hidden, ""},
		{"cgroup2", "/sys/fs/cgroup", "cgroup2", hidden, "nsdelegate"},
		{"run", "/run", "tmpfs", unix.MS_NOSUID | unix.MS_NODEV, "mode=0755,size=16m"},
		{"homes", vm.GuestHomeRoot, "tmpfs", unix.MS_NOSUID | unix.MS_NODEV, "mode=1733"},
	} {
		if mt.target == "/dev/pts" || mt.target == "/dev/mqueue" {
			if err := os.MkdirAll(mt.target, 0o755); err != nil {
				return err
			}
		}
		err := unix.Mount(mt.source, mt.target, mt.fstype, mt.flags, mt.data)
		// The kernel mounts devtmpfs at /dev itself (DEVTMPFS_MOUNT).
		if errors.Is(err, unix.EBUSY) && mt.fstype == "devtmpfs" {
			continue
		}
		if err != nil {
			return fmt.Errorf("mounting %s at %s: %w", mt.fstype, mt.target, err)
		}
	}
	client, err := user.Lookup(vm.GuestClientUser)
	if err != nil {
		return err
	}
	uid, _ := strconv.Atoi(client.Uid)
	gid, _ := strconv.Atoi(client.Gid)
	run := filepath.Dir(vm.GuestAttachPath)
	if err := os.Mkdir(run, 0o700); err != nil {
		return err
	}
	return os.Chown(run, uid, gid)
}

// keeperCgroup makes the keeper's group, bounded below the guest's memory
// by guestReserve, with the controllers the keeper delegates to its
// spawns, and returns it open for the keeper's start.
func keeperCgroup() (*os.File, error) {
	if err := os.WriteFile("/sys/fs/cgroup/cgroup.subtree_control", []byte("+memory +cpu +pids"), 0o644); err != nil {
		return nil, fmt.Errorf("enabling the guest's controllers: %w", err)
	}
	if err := os.Mkdir(keeperGroup, 0o755); err != nil {
		return nil, err
	}
	total, err := memTotal()
	if err != nil {
		return nil, err
	}
	if total <= 2*guestReserve {
		return nil, fmt.Errorf("the guest has %d bytes of memory, too few for its keeper", total)
	}
	for file, value := range map[string]string{
		"memory.max":      strconv.FormatUint(total-guestReserve, 10),
		"memory.swap.max": "0",
	} {
		if err := os.WriteFile(filepath.Join(keeperGroup, file), []byte(value), 0o644); err != nil {
			return nil, fmt.Errorf("the keeper's %s: %w", file, err)
		}
	}
	return os.Open(keeperGroup)
}

func memTotal() (uint64, error) {
	raw, err := os.ReadFile("/proc/meminfo")
	if err != nil {
		return 0, err
	}
	for _, line := range strings.Split(string(raw), "\n") {
		if rest, ok := strings.CutPrefix(line, "MemTotal:"); ok {
			kb, err := strconv.ParseUint(strings.TrimSuffix(strings.TrimSpace(rest), " kB"), 10, 64)
			return kb << 10, err
		}
	}
	return 0, errors.New("/proc/meminfo has no MemTotal")
}
