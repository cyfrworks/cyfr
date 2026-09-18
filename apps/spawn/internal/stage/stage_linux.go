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
	"strconv"
	"syscall"

	"golang.org/x/sys/unix"

	"github.com/cyfr/spawn/internal/procfs"
	"github.com/cyfr/spawn/internal/protocol"
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
	// read, and it is the one descriptor above 2 the command keeps.
	ControlFD = 5
)

// CommandControlFD is the descriptor the executed command finds its control
// channel on.
const CommandControlFD = 3

// ExitFailed is the stage's exit status when it cannot execute the command.
const ExitFailed = 127

// Main runs `cyfr-spawn stage`. It does not return on success.
func Main() int {
	status := os.NewFile(StatusFD, "status")
	fail := func(format string, args ...any) int {
		fmt.Fprintf(status, format, args...)
		return ExitFailed
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
	if err := checkCredentials(spec); err != nil {
		return fail("credentials: %v", err)
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
	// Every descriptor above the command's is marked close-on-exec; with a
	// control channel, its socket is first moved to the command's fd 3
	// (Dup3 with no flags leaves the new descriptor open across exec) so it
	// is the one descriptor above 2 the command inherits.
	keep := SpecFD
	if spec.Control {
		if err := unix.Dup3(ControlFD, CommandControlFD, 0); err != nil {
			return fail("control channel: %v", err)
		}
		keep = CommandControlFD + 1
	}
	if err := closeOnExecFrom(keep); err != nil {
		return fail("descriptors: %v", err)
	}
	err = syscall.Exec(path, spec.Argv, spec.Environ())
	return fail("exec %s: %v", path, err)
}

// checkCredentials refuses to continue unless the process is exactly the
// spec's uid and gid with no supplementary groups, no capabilities and
// no_new_privs set.
func checkCredentials(spec Spec) error {
	ruid, euid, suid := unix.Getresuid()
	rgid, egid, sgid := unix.Getresgid()
	if ruid != spec.UID || euid != spec.UID || suid != spec.UID {
		return fmt.Errorf("running as uid %d/%d/%d, not %d", ruid, euid, suid, spec.UID)
	}
	if rgid != spec.GID || egid != spec.GID || sgid != spec.GID {
		return fmt.Errorf("running as gid %d/%d/%d, not %d", rgid, egid, sgid, spec.GID)
	}
	groups, err := unix.Getgroups()
	if err != nil {
		return err
	}
	if len(groups) != 0 {
		return fmt.Errorf("supplementary groups %v", groups)
	}
	raw, err := os.ReadFile("/proc/self/status")
	if err != nil {
		return err
	}
	st, err := procfs.ParseStatus(raw)
	if err != nil {
		return err
	}
	if st.CapEff != 0 || st.CapPrm != 0 || st.CapAmb != 0 || !st.NoNewPrivs {
		return errors.New("capabilities remain or no_new_privs is unset")
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
