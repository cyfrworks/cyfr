// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package cmd

import "golang.org/x/sys/unix"

// hasDevice is whether path is this machine's misc character device of
// minor.
func hasDevice(path string, minor uint32) bool {
	var st unix.Stat_t
	if unix.Stat(path, &st) != nil {
		return false
	}
	return st.Mode&unix.S_IFMT == unix.S_IFCHR && unix.Major(st.Rdev) == 10 && unix.Minor(st.Rdev) == minor
}
