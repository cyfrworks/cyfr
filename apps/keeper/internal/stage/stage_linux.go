// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package stage

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"syscall"

	"golang.org/x/sys/unix"

	"github.com/cyfr/keeper/internal/cgroup"
	"github.com/cyfr/keeper/internal/procfs"
	"github.com/cyfr/keeper/internal/protocol"
)

// File descriptors of a stage process besides the backend's stdio on 0-2.
const (
	// SpecFD is the read end of the spec pipe.
	SpecFD = 3
	// StatusFD is the write end of the exec-status pipe. It closes on a
	// successful exec; otherwise the stage writes its reason there first.
	StatusFD = 4
	// ControlFD is the backend's end of its control channel, present only
	// when the spec says so; the stage moves it to fd 3 once the spec is
	// read.
	ControlFD = 5
	// RelayFD is the backend's end of its relay (Prima.RunnerRelay),
	// present exactly when the stage runs in a namespace of its own; the
	// stage moves it to fd 4. With the control channel it is one of the
	// only descriptors above 2 the command keeps.
	RelayFD = 6
)

// CommandControlFD and CommandRelayFD are the descriptors the executed
// command finds its control channel and its relay on.
const (
	CommandControlFD = 3
	CommandRelayFD   = 4
)

// statusFloor is the least descriptor the status pipe moves to, above
// every descriptor the command is given.
const statusFloor = 10

// ExitFailed is the stage's exit status when it cannot execute the command.
const ExitFailed = 127

// ProbeArg, after `stage`, makes the stage the keeper's start-time proof
// that this host lets it isolate a spawn: it reads a Probe instead of a
// Spec, becomes the probe's uid and gid, drops every capability set as a
// spawn's stage does, and exits 0 without executing anything.
const ProbeArg = "probe"

// Probe is what the keeper hands a probing stage over its spec pipe.
type Probe struct {
	UID int `json:"uid"`
	GID int `json:"gid"`
}

// Main runs `cyfr-keeper stage`. It does not return on success.
//
// A stage of a pool that shares the keeper's namespaces starts already
// running as the spawn's uid and gid. A stage of an isolated pool is the
// keeper's binary in its stage mode, cloned into a user and network
// namespace of its own and holding, inside that namespace only, SETUID,
// SETGID and SETPCAP as ambient capabilities and nothing outside it. It is
// blocked reading its spec from an inherited pipe until the keeper, from
// the parent side, has written its setgroups (deny), gid_map and uid_map,
// each mapping the pooled id to itself, and placed it in its cgroup: a
// process inside a new user namespace cannot map an id its parent could
// not, nor join a cgroup its owner did not delegate. Only once the spec
// arrives does it become the pooled uid and gid, drop every set, bounding,
// inheritable, permitted, effective and ambient, set no_new_privs, and
// execute the command, which then holds no capability anywhere and has no
// route out of its namespace: the loopback stays down, and a descriptor it
// inherited, its control channel on fd 3 and its relay on fd 4, is its
// only way to anything.
func Main() int {
	// Capabilities and no_new_privs belong to a thread, and execve takes
	// the credentials of the thread that calls it: the drop, the check and
	// the exec all happen on this one.
	runtime.LockOSThread()
	// The status pipe moves above the command's descriptors, close-on-exec,
	// so fd 4 is free for the relay and the pipe still closes on exec.
	status := os.NewFile(StatusFD, "status")
	if moved, err := unix.FcntlInt(StatusFD, unix.F_DUPFD_CLOEXEC, statusFloor); err == nil {
		_ = status.Close()
		status = os.NewFile(uintptr(moved), "status")
	} else {
		fmt.Fprintf(status, "status: %v", err)
		return ExitFailed
	}
	fail := func(format string, args ...any) int {
		fmt.Fprintf(status, format, args...)
		return ExitFailed
	}
	if len(os.Args) > 2 && os.Args[2] == ProbeArg {
		if err := probe(); err != nil {
			return fail("%v", err)
		}
		return 0
	}

	// The spec file is closed by hand: fd 3 is reused for the control
	// channel below, and a finalizer must not close it later.
	specFile := os.NewFile(SpecFD, "spec")
	data, err := io.ReadAll(io.LimitReader(specFile, 2*protocol.MaxLineBytes))
	_ = specFile.Close()
	if err != nil {
		return fail("spec: %v", err)
	}
	var spec Spec
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&spec); err != nil {
		return fail("spec: undecodable")
	}
	if err := spec.Validate(); err != nil {
		return fail("spec: %v", err)
	}
	isolated, err := ownNamespace(spec.UID, spec.GID)
	if err != nil {
		return fail("namespace: %v", err)
	}
	if isolated {
		if err := become(spec.UID, spec.GID); err != nil {
			return fail("credentials: %v", err)
		}
	}
	if err := dropCapabilities(isolated); err != nil {
		return fail("capabilities: %v", err)
	}
	if err := checkCredentials(spec.UID, spec.GID, isolated); err != nil {
		return fail("credentials: %v", err)
	}
	if err := checkCgroup(spec); err != nil {
		return fail("cgroup: %v", err)
	}

	syscall.Umask(0o077)
	if err := os.Mkdir(spec.Home, 0o700); err != nil {
		return fail("home: %v", err)
	}
	if err := os.Mkdir(filepath.Join(spec.Home, "tmp"), 0o700); err != nil {
		return fail("home: %v", err)
	}
	if err := setLimits(spec.Limits); err != nil {
		return fail("rlimits: %v", err)
	}
	if err := os.Chdir(spec.Home); err != nil {
		return fail("home: %v", err)
	}
	path, err := LookPath(spec.Argv[0])
	if err != nil {
		return fail("exec: %v", err)
	}
	// Every descriptor above the command's is marked close-on-exec; the
	// control channel's socket is first moved to the command's fd 3 and an
	// isolated spawn's relay to its fd 4 (Dup3 with no flags leaves the new
	// descriptor open across exec), so they are the only descriptors above
	// 2 the command inherits.
	keep := SpecFD
	if spec.Control {
		if err := unix.Dup3(ControlFD, CommandControlFD, 0); err != nil {
			return fail("control channel: %v", err)
		}
		keep = CommandControlFD + 1
	}
	if isolated {
		if err := checkSocket(RelayFD); err != nil {
			return fail("relay: %v", err)
		}
		if err := unix.Dup3(RelayFD, CommandRelayFD, 0); err != nil {
			return fail("relay: %v", err)
		}
		keep = CommandRelayFD + 1
	}
	if err := closeOnExecFrom(keep); err != nil {
		return fail("descriptors: %v", err)
	}
	err = syscall.Exec(path, spec.Argv, spec.Environ())
	return fail("exec %s: %v", path, err)
}

// probe is the stage's start-time proof for the keeper: the namespace the
// keeper cloned it into maps the probe's ids, the stage becomes them and
// drops every capability set, and the check a spawn's stage makes before
// it executes the command passes.
func probe() error {
	specFile := os.NewFile(SpecFD, "spec")
	data, err := io.ReadAll(io.LimitReader(specFile, 4096))
	_ = specFile.Close()
	if err != nil {
		return fmt.Errorf("probe: %w", err)
	}
	var p Probe
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&p); err != nil || p.UID <= 0 || p.GID <= 0 {
		return errors.New("probe: undecodable")
	}
	isolated, err := ownNamespace(p.UID, p.GID)
	if err != nil {
		return fmt.Errorf("namespace: %w", err)
	}
	if !isolated {
		return errors.New("namespace: the probe does not run in a user namespace mapping only its ids")
	}
	if err := become(p.UID, p.GID); err != nil {
		return fmt.Errorf("credentials: %w", err)
	}
	if err := dropCapabilities(true); err != nil {
		return fmt.Errorf("capabilities: %w", err)
	}
	return checkCredentials(p.UID, p.GID, true)
}

// ownNamespace reports whether the stage runs in a user namespace of its
// own, as the keeper makes one for an isolated spawn: one whose only
// mappings are uid to itself and gid to itself, with setgroups denied. A
// user namespace mapping anything else is the keeper's own (the initial
// one, or a container's), and any other partial state is refused.
func ownNamespace(uid, gid int) (bool, error) {
	uidMap, err := os.ReadFile("/proc/self/uid_map")
	if err != nil {
		return false, err
	}
	gidMap, err := os.ReadFile("/proc/self/gid_map")
	if err != nil {
		return false, err
	}
	ownUID, ownGID := identityOnly(uidMap, uid), identityOnly(gidMap, gid)
	switch {
	case !ownUID && !ownGID && len(bytes.TrimSpace(uidMap)) > 0 && len(bytes.TrimSpace(gidMap)) > 0:
		return false, nil
	case !ownUID || !ownGID:
		return false, fmt.Errorf("uid_map %q and gid_map %q are not the spawn's ids mapped to themselves", bytes.TrimSpace(uidMap), bytes.TrimSpace(gidMap))
	}
	setgroups, err := os.ReadFile("/proc/self/setgroups")
	if err != nil {
		return false, err
	}
	if string(bytes.TrimSpace(setgroups)) != "deny" {
		return false, fmt.Errorf("setgroups is %q, not deny", bytes.TrimSpace(setgroups))
	}
	return true, nil
}

// identityOnly reports whether an id map file holds exactly one mapping, of
// id to itself and nothing else.
func identityOnly(idMap []byte, id int) bool {
	lines := strings.Split(strings.TrimSpace(string(idMap)), "\n")
	if len(lines) != 1 {
		return false
	}
	fields := strings.Fields(lines[0])
	want := []string{strconv.Itoa(id), strconv.Itoa(id), "1"}
	return len(fields) == 3 && fields[0] == want[0] && fields[1] == want[1] && fields[2] == want[2]
}

// become sets every uid and gid of the process to the spawn's, as the stage
// of an isolated pool does for itself inside its namespace, where it holds
// SETUID and SETGID. Its supplementary groups are the keeper's, which the
// keeper cleared before it served an isolated pool, since setgroups is
// denied here.
func become(uid, gid int) error {
	if err := syscall.Setresgid(gid, gid, gid); err != nil {
		return fmt.Errorf("setresgid %d: %w", gid, err)
	}
	if err := syscall.Setresuid(uid, uid, uid); err != nil {
		return fmt.Errorf("setresuid %d: %w", uid, err)
	}
	return nil
}

// dropCapabilities empties this thread's capability sets and sets
// no_new_privs. In a namespace of its own the stage holds SETPCAP there and
// drops the whole bounding set first; a stage sharing the keeper's
// namespace holds no SETPCAP, cannot drop a bounding capability, and keeps
// the keeper's bounding set, which no_new_privs keeps from being raised by
// anything it executes.
func dropCapabilities(isolated bool) error {
	if isolated {
		for c := 0; c < 64; c++ {
			err := unix.Prctl(unix.PR_CAPBSET_DROP, uintptr(c), 0, 0, 0)
			if errors.Is(err, unix.EINVAL) {
				// Past the kernel's last capability.
				break
			}
			if err != nil {
				return fmt.Errorf("dropping capability %d from the bounding set: %w", c, err)
			}
		}
	}
	if err := unix.Prctl(unix.PR_CAP_AMBIENT, unix.PR_CAP_AMBIENT_CLEAR_ALL, 0, 0, 0); err != nil {
		return fmt.Errorf("clearing the ambient set: %w", err)
	}
	header := unix.CapUserHeader{Version: unix.LINUX_CAPABILITY_VERSION_3}
	var none [2]unix.CapUserData
	if err := unix.Capset(&header, &none[0]); err != nil {
		return fmt.Errorf("clearing the inheritable, permitted and effective sets: %w", err)
	}
	if err := unix.Prctl(unix.PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0); err != nil {
		return fmt.Errorf("PR_SET_NO_NEW_PRIVS: %w", err)
	}
	return nil
}

// checkCredentials refuses to continue unless this thread is exactly uid
// and gid with no supplementary groups and no_new_privs set, and holds no
// inheritable, permitted, effective or ambient capability. In a namespace
// of its own its bounding set is empty too; sharing the keeper's, it is the
// keeper's own, which the keeper's start holds to SETUID, SETGID and KILL
// and which nothing executed under no_new_privs can raise.
func checkCredentials(uid, gid int, isolated bool) error {
	ruid, euid, suid := unix.Getresuid()
	rgid, egid, sgid := unix.Getresgid()
	if ruid != uid || euid != uid || suid != uid {
		return fmt.Errorf("running as uid %d/%d/%d, not %d", ruid, euid, suid, uid)
	}
	if rgid != gid || egid != gid || sgid != gid {
		return fmt.Errorf("running as gid %d/%d/%d, not %d", rgid, egid, sgid, gid)
	}
	groups, err := unix.Getgroups()
	if err != nil {
		return err
	}
	if len(groups) != 0 {
		return fmt.Errorf("supplementary groups %v", groups)
	}
	raw, err := os.ReadFile("/proc/thread-self/status")
	if err != nil {
		return err
	}
	st, err := procfs.ParseStatus(raw)
	if err != nil {
		return err
	}
	bounding := procfs.AnyBounding
	if isolated {
		bounding = 0
	}
	return procfs.CheckNoCaps(st, bounding)
}

// checkSocket refuses a descriptor that is not a stream socket.
func checkSocket(fd int) error {
	kind, err := unix.GetsockoptInt(fd, unix.SOL_SOCKET, unix.SO_TYPE)
	if err != nil {
		return fmt.Errorf("fd %d: %w", fd, err)
	}
	if kind != unix.SOCK_STREAM {
		return fmt.Errorf("fd %d is not a stream socket", fd)
	}
	return nil
}

// checkCgroup refuses to continue unless the process is in the memory-bounded
// group the spec names: a command asked to run under a bound never runs
// outside one.
func checkCgroup(spec Spec) error {
	if spec.Cgroup == "" {
		return nil
	}
	raw, err := os.ReadFile(cgroup.SelfPath)
	if err != nil {
		return err
	}
	own, err := cgroup.Own(raw)
	if err != nil {
		return err
	}
	if own != spec.Cgroup {
		return fmt.Errorf("running in %s, not %s", own, spec.Cgroup)
	}
	return nil
}

func setLimits(l protocol.Limits) error {
	for _, r := range []struct {
		name     string
		resource int
		value    uint64
	}{
		{"nofile", unix.RLIMIT_NOFILE, l.Nofile},
		{"nproc", unix.RLIMIT_NPROC, l.Nproc},
		{"core", unix.RLIMIT_CORE, l.Core},
		{"fsize", unix.RLIMIT_FSIZE, l.Fsize},
	} {
		if err := syscall.Setrlimit(r.resource, &syscall.Rlimit{Cur: r.value, Max: r.value}); err != nil {
			return fmt.Errorf("%s: %w", r.name, err)
		}
	}
	return nil
}

// closeOnExecFrom marks every descriptor from first upward close-on-exec,
// so the executed command holds only fds 0-2. Descriptors are marked rather
// than closed because the Go runtime still uses some of them until exec.
func closeOnExecFrom(first int) error {
	err := unix.CloseRange(uint(first), math.MaxUint32, unix.CLOSE_RANGE_CLOEXEC)
	if err == nil {
		return nil
	}
	if !errors.Is(err, unix.ENOSYS) && !errors.Is(err, unix.EINVAL) {
		return err
	}
	entries, err := os.ReadDir("/proc/self/fd")
	if err != nil {
		return err
	}
	for _, e := range entries {
		fd, err := strconv.Atoi(e.Name())
		if err != nil || fd < first {
			continue
		}
		if _, err := unix.FcntlInt(uintptr(fd), unix.F_SETFD, unix.FD_CLOEXEC); err != nil && !errors.Is(err, unix.EBADF) {
			return fmt.Errorf("fd %d: %w", fd, err)
		}
	}
	return nil
}
