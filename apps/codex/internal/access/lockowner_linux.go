// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package access

import (
	"os"
	"strconv"
	"strings"
	"syscall"
)

// lockOwner is the pid the kernel's lock table names for the flock on
// the file at path, 0 when it names none it can show.
func lockOwner(path string) int {
	var st syscall.Stat_t
	if syscall.Stat(path, &st) != nil {
		return 0
	}
	data, err := os.ReadFile("/proc/locks")
	if err != nil {
		return 0
	}
	// "1: FLOCK  ADVISORY  WRITE 4242 08:02:131 0 EOF": the pid, then the
	// device and the inode.
	for _, line := range strings.Split(string(data), "\n") {
		f := strings.Fields(line)
		if len(f) < 6 || f[1] != "FLOCK" {
			continue
		}
		dev := strings.Split(f[5], ":")
		if len(dev) != 3 || dev[2] != strconv.FormatUint(uint64(st.Ino), 10) {
			continue
		}
		if pid, err := strconv.Atoi(f[4]); err == nil && pid > 0 {
			return pid
		}
	}
	return 0
}
