// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// sameProgram is whether process pid runs the program at path, as /proc
// names the program each process runs.
func sameProgram(pid int, path string) bool {
	exe, err := os.Readlink("/proc/" + strconv.Itoa(pid) + "/exe")
	return err == nil && filepath.Clean(strings.TrimSuffix(exe, " (deleted)")) == filepath.Clean(path)
}
