// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package main

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

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

// keeperStop bounds the keeper's own end, every role and space retired,
// once the host ends the machine; past it the keeper's group is killed.
const keeperStop = 5 * time.Second

// guardWait bounds the guest's guard's start to its ready file: every rule
// in, before the keeper proves it.
const guardWait = 10 * time.Second

// initMain is the guest's first process. It makes the guest's mounts and
// the keeper's group, the guest's only vsock sockets, its three listeners,
// before anything else runs, starts the guest's guard and, once the guard
// is ready, the keeper, which runs under the keeper's own system-call
// policy (keeperMain) and so can make no vsock socket of its own; it hands
// the relay its two listeners on vm.GuestHandoffPath, answers the end's
// port itself, reaps every orphan, and ends the machine when the keeper
// ends.
// It returns only when it cannot go on, which ends the machine too
// (panic=-1, vm's boot arguments).
func initMain() int {
	roleUID, err := mounts()
	if err != nil {
		logf("refusing to start: %v", err)
		return 1
	}
	control, err := listenVsock(vm.ControlPort)
	if err != nil {
		logf("refusing to start: the control port: %v", err)
		return 1
	}
	attach, err := listenVsock(vm.AttachPort)
	if err != nil {
		logf("refusing to start: the attach port: %v", err)
		return 1
	}
	end, err := listenVsock(vm.EndPort)
	if err != nil {
		logf("refusing to start: the end's port: %v", err)
		return 1
	}
	handoff, err := handoffListener(roleUID)
	if err != nil {
		logf("refusing to start: the relay's handoff: %v", err)
		return 1
	}
	go handOff(handoff, roleUID, control, attach)
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
	if err := startGuard(self); err != nil {
		logf("refusing to start: the guard: %v", err)
		return 1
	}
	key, err := roleKey()
	if err != nil {
		logf("refusing to start: %v", err)
		return 1
	}
	cmd := exec.Command(self, "keeper")
	cmd.Env = []string{path, vm.GuestRoleKey + "=" + key}
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
	go func() {
		conn, err := acceptHost(end)
		if err != nil {
			logf("the end's port: %v", err)
			return
		}
		_, _ = conn.Write([]byte(vm.EndAck))
		_ = conn.Close()
		logf("the host ends the machine: its keeper stops")
		_ = unix.Kill(keeper, unix.SIGTERM)
		time.Sleep(keeperStop) // a bound on the keeper's own end, not a wait for an event
		_ = os.WriteFile(filepath.Join(keeperGroup, "cgroup.kill"), []byte("1"), 0o644)
	}()
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

const path = "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

// mounts are the guest's own filesystems over its read-only root, the
// image's programs. They are the Locus container's, so the keeper and the
// guard find what they find there: a /proc, /sys and /dev of the guest's
// own, the POSIX message queues the keeper's residue check reads, the
// cgroup2 tree, a /run holding the guard's folders and /run/locus, root's,
// 0711, with the role's run folder, its uid's own, 0700, and the role's
// homes, mode 1733. There is no writable /tmp or /dev/shm, which the keeper
// refuses.
func mounts() (roleUID int, err error) {
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
		{"homes", filepath.Join(vm.GuestHomeRoot, vm.GuestRole), "tmpfs", unix.MS_NOSUID | unix.MS_NODEV, "mode=1733"},
	} {
		if mt.target == "/dev/pts" || mt.target == "/dev/mqueue" {
			if err := os.MkdirAll(mt.target, 0o755); err != nil {
				return 0, err
			}
		}
		err := unix.Mount(mt.source, mt.target, mt.fstype, mt.flags, mt.data)
		// The kernel mounts devtmpfs at /dev itself (DEVTMPFS_MOUNT).
		if errors.Is(err, unix.EBUSY) && mt.fstype == "devtmpfs" {
			continue
		}
		if err != nil {
			return 0, fmt.Errorf("mounting %s at %s: %w", mt.fstype, mt.target, err)
		}
	}
	role, err := user.Lookup("locus-" + vm.GuestRole)
	if err != nil {
		return 0, err
	}
	uid, _ := strconv.Atoi(role.Uid)
	gid, _ := strconv.Atoi(role.Gid)
	for _, dir := range []struct {
		path     string
		mode     os.FileMode
		uid, gid int
	}{
		{"/run/cyfr-guard", 0o755, 0, 0},
		{filepath.Dir(vm.GuestGuardControl), 0o700, 0, 0},
		{filepath.Dir(vm.GuestRunDir), 0o711, 0, 0},
		{vm.GuestRunDir, 0o700, uid, gid},
	} {
		if err := os.Mkdir(dir.path, dir.mode); err != nil {
			return 0, err
		}
		if err := os.Chmod(dir.path, dir.mode); err != nil {
			return 0, err
		}
		if err := os.Chown(dir.path, dir.uid, dir.gid); err != nil {
			return 0, err
		}
	}
	return uid, nil
}

// handoffListener listens on vm.GuestHandoffPath, in the role's run folder,
// a socket the role's uid alone may connect to.
func handoffListener(roleUID int) (*net.UnixListener, error) {
	l, err := net.ListenUnix("unix", &net.UnixAddr{Name: vm.GuestHandoffPath, Net: "unix"})
	if err != nil {
		return nil, err
	}
	l.SetUnlinkOnClose(false)
	if err := os.Chmod(vm.GuestHandoffPath, 0o600); err != nil {
		return nil, err
	}
	if err := os.Chown(vm.GuestHandoffPath, roleUID, -1); err != nil {
		return nil, err
	}
	return l, nil
}

// handOff gives each connection of the role's uid the control and attach
// listeners, one byte and two descriptors, and closes it: each start of
// the role, the relay, takes them again. A peer of another uid gets
// nothing.
func handOff(l *net.UnixListener, roleUID, control, attach int) {
	for {
		conn, err := l.AcceptUnix()
		if err != nil {
			logf("the relay's handoff: %v", err)
			return
		}
		go func() {
			defer conn.Close()
			raw, err := conn.SyscallConn()
			if err != nil {
				return
			}
			var cred *unix.Ucred
			_ = raw.Control(func(fd uintptr) {
				cred, err = unix.GetsockoptUcred(int(fd), unix.SOL_SOCKET, unix.SO_PEERCRED)
			})
			if err != nil || cred == nil || int(cred.Uid) != roleUID {
				logf("the relay's handoff: refused a peer that is not uid %d", roleUID)
				return
			}
			if _, _, err := conn.WriteMsgUnix([]byte{'l'}, unix.UnixRights(control, attach), nil); err != nil {
				logf("the relay's handoff: %v", err)
			}
		}()
	}
}

// startGuard starts the guest's guard, `cyfr-locus guard-control`, as the
// Locus container's guard runs: forwarding on, ICMP unlimited, NET_ADMIN
// alone, its control on GuestGuardControl. It waits guardWait for the ready
// file, written once every rule is in. The guest has no network card, so
// the guard's routes lead nowhere: a space it routes reaches only what the
// guard's own namespace does, which is nothing past the guest. Its control
// plane is a documentation address (RFC 5737), refused as cyfr's would be.
func startGuard(self string) error {
	for file, value := range map[string]string{
		"/proc/sys/net/ipv4/ip_forward":     "1",
		"/proc/sys/net/ipv4/icmp_ratelimit": "0",
	} {
		if err := os.WriteFile(file, []byte(value), 0o644); err != nil {
			return err
		}
	}
	cmd := exec.Command(self, "guard")
	cmd.Env = []string{path, "CYFR_GUARD_CONTROL=" + vm.GuestGuardControl, "CYFR_GUARD_CONTROL_PLANE=192.0.2.1",
		"CYFR_PRIVATE_EGRESS_TARGETS="}
	cmd.Stdout, cmd.Stderr = os.Stderr, os.Stderr
	if err := cmd.Start(); err != nil {
		return err
	}
	deadline := time.Now().Add(guardWait)
	for {
		if _, err := os.Stat("/run/cyfr-guard/ready"); err == nil {
			return nil
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("no ready file within %s", guardWait)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// roleKey is the role's key: the keeper starts a role only with one. The
// relay reads none; it is random so nothing holds it.
func roleKey() (string, error) {
	var b [32]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(b[:]), nil
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
