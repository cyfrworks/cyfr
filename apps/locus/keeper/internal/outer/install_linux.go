// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package outer

import (
	"errors"
	"fmt"
	"os"
	"runtime"
	"unsafe"

	"golang.org/x/net/bpf"
	"golang.org/x/sys/unix"
)

// Load is the filter of the profile at profilePath for a container holding
// caps, on the running kernel: the table at tablePath numbers its calls and
// uname gives its release.
func Load(profilePath, tablePath string, caps []string) ([]bpf.RawInstruction, error) {
	profile, err := os.ReadFile(profilePath)
	if err != nil {
		return nil, err
	}
	tbl, err := os.ReadFile(tablePath)
	if err != nil {
		return nil, err
	}
	table, err := ParseTable(tbl)
	if err != nil {
		return nil, err
	}
	var uts unix.Utsname
	if err := unix.Uname(&uts); err != nil {
		return nil, fmt.Errorf("uname: %w", err)
	}
	return Compile(profile, table, caps, unix.ByteSliceToString(uts.Release[:]))
}

// Install installs prog on every thread of the calling process
// (SECCOMP_FILTER_FLAG_TSYNC), and every thread and process they start
// inherits it across exec; nothing lifts it. It does not set no_new_privs:
// the kernel takes the filter only from a thread that holds CAP_SYS_ADMIN
// in its user namespace or has set no_new_privs itself, and in Go that is
// the thread the calling goroutine is locked to. A process that already
// runs under filters keeps them beside this one. An error means no thread
// took the filter.
func Install(prog []bpf.RawInstruction) error {
	if len(prog) == 0 || len(prog) > unix.BPF_MAXINSNS {
		return errors.New("the filter is empty or too long")
	}
	filter := make([]unix.SockFilter, len(prog))
	for i, insn := range prog {
		filter[i] = unix.SockFilter{Code: insn.Op, Jt: insn.Jt, Jf: insn.Jf, K: insn.K}
	}
	program := unix.SockFprog{Len: uint16(len(filter)), Filter: &filter[0]}
	r, _, errno := unix.Syscall(unix.SYS_SECCOMP, unix.SECCOMP_SET_MODE_FILTER, unix.SECCOMP_FILTER_FLAG_TSYNC,
		uintptr(unsafe.Pointer(&program)))
	runtime.KeepAlive(filter)
	if errno != 0 {
		return fmt.Errorf("seccomp: %w", errno)
	}
	// With TSYNC the kernel answers a thread it cannot synchronize by that
	// thread's id, and installs nothing.
	if r != 0 {
		return fmt.Errorf("seccomp: thread %d cannot take the filter", r)
	}
	return nil
}
