// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package shell

import (
	"syscall"

	"golang.org/x/sys/windows"
)

// soExclusiveAddrUse is Winsock's SO_EXCLUSIVEADDRUSE, ~SO_REUSEADDR.
const soExclusiveAddrUse = ^windows.SO_REUSEADDR

// exclusiveAddress sets SO_EXCLUSIVEADDRUSE: Windows otherwise lets a
// later socket that sets SO_REUSEADDR bind the same address and take the
// connections meant for this one.
func exclusiveAddress(_, _ string, c syscall.RawConn) error {
	var set error
	err := c.Control(func(fd uintptr) {
		set = windows.SetsockoptInt(windows.Handle(fd), windows.SOL_SOCKET, soExclusiveAddrUse, 1)
	})
	if err != nil {
		return err
	}
	return set
}
