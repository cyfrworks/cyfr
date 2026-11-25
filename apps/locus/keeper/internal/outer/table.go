// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package outer holds a person's machine under the outer system-call policy
// the host's Locus container runs under: Docker's seccomp profile
// (apps/locus/keeper/seccomp/keeper.json, /etc/cyfr/keeper.json in the
// image). A guest has no Docker, so the package compiles that profile, as
// Docker, runc and libseccomp apply it to a container on amd64, to a
// classic-BPF seccomp filter and installs it.
package outer

import (
	"bufio"
	"bytes"
	"errors"
	"fmt"
	"strconv"
	"strings"
)

// ParseTable reads a kernel's x86-64 system-call table, in the format of
// Linux's arch/x86/entry/syscalls/syscall_64.tbl: one call per line as
// `<nr> <abi> <name> [entry point] [compat entry point] [noreturn]`,
// whitespace separated, with `#` starting a comment. It keeps the calls of
// the 64-bit ABI (abi `common` or `64`) and skips the x32 ones, which the
// filter refuses whole. An empty table, an unknown abi, a malformed number
// or a name or number listed twice is refused: the table is the kernel the
// filter describes, and a wrong one describes another.
func ParseTable(tbl []byte) (map[string]uint32, error) {
	table := map[string]uint32{}
	numbered := map[uint32]string{}
	lines := bufio.NewScanner(bytes.NewReader(tbl))
	for line := 1; lines.Scan(); line++ {
		text, _, _ := strings.Cut(lines.Text(), "#")
		fields := strings.Fields(text)
		if len(fields) == 0 {
			continue
		}
		if len(fields) < 3 {
			return nil, fmt.Errorf("syscall table line %d: want <nr> <abi> <name>, got %q", line, text)
		}
		nr64, err := strconv.ParseUint(fields[0], 10, 32)
		if err != nil {
			return nil, fmt.Errorf("syscall table line %d: number %q: %w", line, fields[0], err)
		}
		nr, abi, name := uint32(nr64), fields[1], fields[2]
		switch abi {
		case "common", "64":
		case "x32":
			continue
		default:
			return nil, fmt.Errorf("syscall table line %d: abi %q is not x86-64's", line, abi)
		}
		if _, ok := table[name]; ok {
			return nil, fmt.Errorf("syscall table line %d: %s is listed twice", line, name)
		}
		if other, ok := numbered[nr]; ok {
			return nil, fmt.Errorf("syscall table line %d: %d is both %s and %s", line, nr, other, name)
		}
		table[name], numbered[nr] = nr, name
	}
	if err := lines.Err(); err != nil {
		return nil, fmt.Errorf("syscall table: %w", err)
	}
	if len(table) == 0 {
		return nil, errors.New("syscall table names no 64-bit call")
	}
	return table, nil
}
