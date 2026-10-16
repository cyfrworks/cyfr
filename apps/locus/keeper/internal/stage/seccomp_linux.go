// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package stage

import (
	"errors"
	"fmt"
	"runtime"
	"unsafe"

	"golang.org/x/net/bpf"
	"golang.org/x/sys/unix"
)

// The runner's own seccomp filter. The runtime's container runs under the
// keeper's profile (apps/locus/keeper/seccomp/keeper.json), which lets a
// clone make a user and a network namespace because the keeper makes each
// isolated spawn that way. Without a filter of its own a runner inherits that
// allowance and could clone a user namespace of its own inside the one it
// was given, holding every capability there. The stage of an isolated spawn
// therefore installs this filter on itself after it has dropped every
// capability and set no_new_privs, and before it executes the command; the
// filter stays with the command across exec and with every thread and
// process the command starts, and nothing in it can be lifted.
//
// The filter refuses, with EPERM, the calls that make or enter a namespace
// or a mount and the kernel interfaces a runner never uses: unshare, setns,
// mount, umount2, pivot_root, keyctl, add_key, request_key, bpf,
// userfaultfd, perf_event_open, and a clone whose flags hold any CLONE_NEW*
// bit. It answers clone3 with ENOSYS, as a kernel without it would, so the
// C library falls back to clone, whose flags the filter can read; clone3
// passes its flags in memory a filter cannot read. A clone without a
// namespace flag, which is how threads and child processes are made, is
// allowed, and so is every other call. A call made under another
// architecture's calling convention (a 32-bit or x32 entry on a 64-bit
// kernel), whose numbers the filter's do not describe, kills the process.

// cloneNamespaceFlags are the CLONE_NEW* bits clone's flags can carry.
// CLONE_NEWTIME shares its value with clone's exit signal and is taken only
// by clone3 and unshare, which the filter refuses whole.
const cloneNamespaceFlags = unix.CLONE_NEWNS | unix.CLONE_NEWCGROUP | unix.CLONE_NEWUTS |
	unix.CLONE_NEWIPC | unix.CLONE_NEWUSER | unix.CLONE_NEWPID | unix.CLONE_NEWNET

// x32SyscallBit marks a call made through the x32 ABI on x86_64.
const x32SyscallBit = 0x40000000

// Offsets into struct seccomp_data: the call's number, its architecture,
// and its arguments, each 64 bits wide.
const (
	seccompDataNR   = 0
	seccompDataArch = 4
	seccompDataArgs = 16
)

// seccompArch is what the filter needs to know of the architecture it runs
// on: its audit value, which argument of clone holds the flags (the second
// on s390x, whose clone takes the stack first), whether a 64-bit argument's
// low word is its second (big-endian), and whether the kernel also takes
// x32 calls under the same audit value.
type seccompArch struct {
	audit      uint32
	cloneFlags int
	bigEndian  bool
	x32        bool
}

// seccompCalls are the numbers, on one architecture, of the calls the
// filter decides.
type seccompCalls struct {
	refused []uint32
	clone   uint32
	clone3  uint32
}

// nativeSeccompArch describes the architecture this binary was built for,
// or fails where the filter has no description of it.
func nativeSeccompArch() (seccompArch, error) {
	switch runtime.GOARCH {
	case "amd64":
		return seccompArch{audit: unix.AUDIT_ARCH_X86_64, x32: true}, nil
	case "arm64":
		return seccompArch{audit: unix.AUDIT_ARCH_AARCH64}, nil
	case "s390x":
		return seccompArch{audit: unix.AUDIT_ARCH_S390X, cloneFlags: 1, bigEndian: true}, nil
	default:
		return seccompArch{}, fmt.Errorf("no runner filter is defined for %s", runtime.GOARCH)
	}
}

// nativeSeccompCalls are the call numbers of this binary's architecture.
func nativeSeccompCalls() seccompCalls {
	return seccompCalls{
		refused: []uint32{
			unix.SYS_UNSHARE, unix.SYS_SETNS, unix.SYS_MOUNT, unix.SYS_UMOUNT2, unix.SYS_PIVOT_ROOT,
			unix.SYS_KEYCTL, unix.SYS_ADD_KEY, unix.SYS_REQUEST_KEY, unix.SYS_BPF, unix.SYS_USERFAULTFD,
			unix.SYS_PERF_EVENT_OPEN,
		},
		clone:  unix.SYS_CLONE,
		clone3: unix.SYS_CLONE3,
	}
}

// runnerFilter is the filter's program for one architecture and its call
// numbers.
func runnerFilter(arch seccompArch, calls seccompCalls) ([]bpf.RawInstruction, error) {
	eperm := bpf.RetConstant{Val: unix.SECCOMP_RET_ERRNO | uint32(unix.EPERM)}
	program := []bpf.Instruction{
		bpf.LoadAbsolute{Off: seccompDataArch, Size: 4},
		bpf.JumpIf{Cond: bpf.JumpEqual, Val: arch.audit, SkipTrue: 1},
		bpf.RetConstant{Val: unix.SECCOMP_RET_KILL_PROCESS},
		bpf.LoadAbsolute{Off: seccompDataNR, Size: 4},
	}
	if arch.x32 {
		program = append(program,
			bpf.JumpIf{Cond: bpf.JumpGreaterOrEqual, Val: x32SyscallBit, SkipFalse: 1},
			bpf.RetConstant{Val: unix.SECCOMP_RET_KILL_PROCESS},
		)
	}
	for _, nr := range calls.refused {
		program = append(program, bpf.JumpIf{Cond: bpf.JumpEqual, Val: nr, SkipFalse: 1}, eperm)
	}
	// Every namespace flag lies in the flags' low word.
	flags := uint32(seccompDataArgs + 8*arch.cloneFlags)
	if arch.bigEndian {
		flags += 4
	}
	program = append(program,
		bpf.JumpIf{Cond: bpf.JumpEqual, Val: calls.clone3, SkipFalse: 1},
		bpf.RetConstant{Val: unix.SECCOMP_RET_ERRNO | uint32(unix.ENOSYS)},
		bpf.JumpIf{Cond: bpf.JumpEqual, Val: calls.clone, SkipFalse: 3},
		bpf.LoadAbsolute{Off: flags, Size: 4},
		bpf.JumpIf{Cond: bpf.JumpBitsSet, Val: cloneNamespaceFlags, SkipFalse: 1},
		eperm,
		bpf.RetConstant{Val: unix.SECCOMP_RET_ALLOW},
	)
	return bpf.Assemble(program)
}

// installRunnerFilter installs the runner's filter on the calling thread,
// which must hold no_new_privs and is the thread that executes the command:
// a filter set with prctl belongs to the thread that sets it, and execve
// keeps it for the program it starts and everything that program starts. An
// error means no filter was installed, and the stage executes nothing.
func installRunnerFilter() error {
	arch, err := nativeSeccompArch()
	if err != nil {
		return err
	}
	raw, err := runnerFilter(arch, nativeSeccompCalls())
	if err != nil {
		return fmt.Errorf("assembling the filter: %w", err)
	}
	if len(raw) == 0 || len(raw) > unix.BPF_MAXINSNS {
		return errors.New("the filter is empty or too long")
	}
	filter := make([]unix.SockFilter, len(raw))
	for i, insn := range raw {
		filter[i] = unix.SockFilter{Code: insn.Op, Jt: insn.Jt, Jf: insn.Jf, K: insn.K}
	}
	program := unix.SockFprog{Len: uint16(len(filter)), Filter: &filter[0]}
	err = unix.Prctl(unix.PR_SET_SECCOMP, unix.SECCOMP_MODE_FILTER, uintptr(unsafe.Pointer(&program)), 0, 0)
	runtime.KeepAlive(filter)
	if err != nil {
		return fmt.Errorf("PR_SET_SECCOMP: %w", err)
	}
	return nil
}
