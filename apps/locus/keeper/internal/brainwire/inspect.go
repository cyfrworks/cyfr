// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package brainwire

import (
	"errors"
	"io/fs"
	"syscall"
)

// Absent is an inspection that found nothing under the name: it, or a
// folder on its way, does not exist, or a step of it is no folder. Any
// other failure to inspect is never an absence, since what cannot be
// looked at may hold a transcript: `forget` refuses on it, and `held`
// leaves out only what it did not positively find.
func Absent(err error) bool {
	return errors.Is(err, fs.ErrNotExist) || errors.Is(err, syscall.ENOTDIR)
}
