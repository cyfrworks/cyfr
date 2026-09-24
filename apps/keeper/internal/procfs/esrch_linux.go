// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package procfs

import (
	"errors"

	"golang.org/x/sys/unix"
)

// isESRCH reports the error a status read returns for a process that exited
// after its directory was listed.
func isESRCH(err error) bool { return errors.Is(err, unix.ESRCH) }
