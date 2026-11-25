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
	"runtime"
	"strconv"
	"strings"
	"syscall"

	"golang.org/x/sys/unix"

	"github.com/cyfr/locus/keeper/internal/cgroup"
	"github.com/cyfr/locus/keeper/internal/home"
	"github.com/cyfr/locus/keeper/internal/pool"
	"github.com/cyfr/locus/keeper/internal/procfs"
	"github.com/cyfr/locus/keeper/internal/protocol"
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
	// RelayFD is a relay space's end of its relay (Prima.RunnerRelay); the
	// stage moves it to fd 4. With the control channel it is one of the
	// only descriptors above 2 the command keeps.
	RelayFD = 6
	// RouteFD is a routed space's socket to the keeper, at RelayFD's place
	// since a space has one of the two: the stage hands its network
	// namespace and name sockets up over it and waits there for the word
	// that the guard admitted its route. The command never holds it.
	RouteFD = 6
	// TerminalFD is a pty spawn's socket to the keeper: the space's first
	// process hands its terminal's master up over it.
	TerminalFD = 7
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
// that this host gives a spawn its space: it reads a Probe instead of a
// Spec, becomes the probe's uid and gid, for a routed probe brings its
// loopback up and binds its name sockets as a routed spawn's stage does,
// clones the space's first process, which builds the space's files, pivots
// into them, drops every capability set and installs the space's filter,
// does the same itself, and exits 0 without executing anything.
const ProbeArg = "probe"

// Probe is what the keeper hands a probing stage over its spec pipe.
type Probe struct {
	UID    int  `json:"uid"`
	GID    int  `json:"gid"`
	Routed bool `json:"routed"`
	// Route says the keeper handed a route socket on RouteFD: the probe
	// hands its route up as a routed spawn's stage does, so the keeper's
	// guard proves it makes one.
	Route bool `json:"route"`
}

// Main runs `cyfr-locus stage`, and ends as the command ended.
//
// The stage is the keeper's binary in its stage mode, cloned into a user,
// network and IPC namespace of its own and holding, inside that namespace
// only, SETUID, SETGID, SETPCAP, SYS_ADMIN, NET_ADMIN and NET_BIND_SERVICE
// as ambient capabilities and nothing outside it. It is blocked reading its spec from
// an inherited pipe until the keeper, from the parent side, has written
// its setgroups (deny), gid_map and uid_map, each mapping the pooled id to
// itself, and placed it in its cgroup: a process inside a new user
// namespace cannot map an id its parent could not, nor join a cgroup its
// owner did not delegate. Only once the spec arrives does it become the
// pooled uid and gid. A routed space's stage then brings its loopback up,
// binds a UDP and a TCP socket at 127.0.0.11:53, hands its network
// namespace and both sockets to the keeper over RouteFD, keeping none of
// them, and waits there for the keeper's word that the guard made its
// route (route_linux.go); a relay space's loopback stays down. Every stage
// then makes a scratch home, clones the space's first process into a pid,
// mount and cgroup namespace (space_linux.go), drops every set of its own,
// bounding, inheritable, permitted, effective and ambient, installs the
// space's seccomp filter (seccomp_linux.go), passes the keeper's signals
// down and ends as the command ended. The space's first process builds the
// space's files and drops every set in turn, and the space's init executes
// the command, which then holds no capability anywhere, can make no
// namespace or mount of its own, sees only its space's processes and files
// and reaches only what its space's reach gives it: a relay space's relay
// on fd 4, or a routed space's route. A step that fails refuses the spawn
// before anything executes.
func Main() int {
	// Capabilities and no_new_privs belong to a thread, and execve takes
	// the credentials of the thread that calls it: the drop, the check and
	// the exec all happen on this one.
	runtime.LockOSThread()
	// A space's first process and its init keep their descriptors where
	// the stage placed them.
	if len(os.Args) > 2 {
		switch os.Args[2] {
		case FirstArg, FirstProbeArg:
			return First(os.Args[2] == FirstProbeArg)
		case InitArg:
			return Init()
		case WaitArg:
			return Wait()
		}
	}
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
	if len(os.Args) > 2 {
		switch os.Args[2] {
		case ProbeArg:
			if err := probe(status); err != nil {
				return fail("%v", err)
			}
			return 0
		}
	}

	// The spec file is closed by hand: fd 3 is free once it is read, and a
	// finalizer must not close it later.
	specFile := os.NewFile(SpecFD, "spec")
	data, err := io.ReadAll(io.LimitReader(specFile, MaxSpecBytes))
	_ = specFile.Close()
	if err != nil {
		return fail("spec: %v", err)
	}
	spec, err := decodeSpec(data)
	if err != nil {
		return fail("%v", err)
	}
	if err := ownNamespace(spec.UID, spec.GID); err != nil {
		return fail("namespace: %v", err)
	}
	if err := become(spec.UID, spec.GID); err != nil {
		return fail("credentials: %v", err)
	}
	if spec.Reach == pool.ReachRouted {
		if err := handRouteUp(RouteFD); err != nil {
			return fail("route: %v", err)
		}
	}
	if err := checkCgroup(spec); err != nil {
		return fail("cgroup: %v", err)
	}
	syscall.Umask(0o077)
	if err := makeHome(spec); err != nil {
		return fail("home: %v", err)
	}
	if err := closeOnExecFrom(TerminalFD + 1); err != nil {
		return fail("descriptors: %v", err)
	}
	err = enter(data, spec.Home, spec.Control, spec.Reach == pool.ReachRelay, spec.Terminal, spec.UID, spec.GID, status)
	return fail("%v", err)
}

// MaxSpecBytes bounds the spec a stage reads.
const MaxSpecBytes = 2 * protocol.MaxLineBytes

// decodeSpec decodes and validates a stage's spec.
func decodeSpec(data []byte) (Spec, error) {
	var spec Spec
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&spec); err != nil {
		return Spec{}, errors.New("spec: undecodable")
	}
	if err := spec.Validate(); err != nil {
		return Spec{}, fmt.Errorf("spec: %w", err)
	}
	return spec, nil
}

// probe is the stage's start-time proof for the keeper: the namespace the
// keeper cloned it into maps the probe's ids, the stage becomes them, a
// routed probe brings its loopback up and binds its two name sockets, and
// the stage clones the space's first process, which builds the space's
// files and drops every capability set, drops every set of its own, passes
// the check a spawn's stage makes before it executes the command, installs
// the space's filter and ends as the first process ended. It returns only
// when a step fails.
func probe(status *os.File) error {
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
	if err := ownNamespace(p.UID, p.GID); err != nil {
		return fmt.Errorf("namespace: %w", err)
	}
	if err := become(p.UID, p.GID); err != nil {
		return fmt.Errorf("credentials: %w", err)
	}
	switch {
	case p.Route:
		if err := handRouteUp(RouteFD); err != nil {
			return fmt.Errorf("the space's route: %w", err)
		}
	case p.Routed:
		udp, tcp, err := nameSockets()
		if err != nil {
			return fmt.Errorf("the space's loopback and name sockets: %w", err)
		}
		_ = unix.Close(udp)
		_ = unix.Close(tcp)
	}
	return enter(nil, "", false, false, false, p.UID, p.GID, status)
}

// ownNamespace refuses to go on unless the stage runs in a user namespace
// of its own, as the keeper makes one for every spawn: one whose only
// mappings are uid to itself and gid to itself, with setgroups denied.
func ownNamespace(uid, gid int) error {
	uidMap, err := os.ReadFile("/proc/self/uid_map")
	if err != nil {
		return err
	}
	gidMap, err := os.ReadFile("/proc/self/gid_map")
	if err != nil {
		return err
	}
	if !identityOnly(uidMap, uid) || !identityOnly(gidMap, gid) {
		return fmt.Errorf("uid_map %q and gid_map %q are not the spawn's ids mapped to themselves", bytes.TrimSpace(uidMap), bytes.TrimSpace(gidMap))
	}
	setgroups, err := os.ReadFile("/proc/self/setgroups")
	if err != nil {
		return err
	}
	if string(bytes.TrimSpace(setgroups)) != "deny" {
		return fmt.Errorf("setgroups is %q, not deny", bytes.TrimSpace(setgroups))
	}
	return nil
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
// does for itself inside its namespace, where it holds SETUID and SETGID.
// Its supplementary groups are the keeper's, which the keeper cleared before
// it served, since setgroups is denied here.
func become(uid, gid int) error {
	if err := syscall.Setresgid(gid, gid, gid); err != nil {
		return fmt.Errorf("setresgid %d: %w", gid, err)
	}
	if err := syscall.Setresuid(uid, uid, uid); err != nil {
		return fmt.Errorf("setresuid %d: %w", uid, err)
	}
	return nil
}

// dropCapabilities empties this thread's capability sets, the whole
// bounding set first, which SETPCAP in its own namespace lets it drop, and
// sets no_new_privs.
func dropCapabilities() error {
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
// capability in any set, the bounding set among them.
func checkCredentials(uid, gid int) error {
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
	return procfs.CheckNoCaps(st, 0)
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

// makeHome makes a scratch home, which must not exist yet; a kept home and
// a role's run folder must exist and be the uid's and 0700.
func makeHome(spec Spec) error {
	if spec.Role != "" {
		return home.CheckOwnDir(spec.Home, spec.UID, errors.New("not the role's run folder"))
	}
	if spec.Kept {
		return home.CheckKeptHome(spec.Home, spec.UID)
	}
	return os.Mkdir(spec.Home, 0o700)
}

// checkCgroup refuses to continue unless the process is in the memory-bounded
// group the spec names: a command asked to run under a bound never runs
// outside one.
func checkCgroup(spec Spec) error {
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
// preserving stdio and any control or relay descriptors below first.
// Descriptors are marked rather than closed because the Go runtime still
// uses some of them until exec.
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
