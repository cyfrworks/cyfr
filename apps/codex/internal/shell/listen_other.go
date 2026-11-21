// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build !windows

package shell

import "syscall"

// exclusiveAddress is nothing here: a Unix listener's address is its
// alone unless both sockets set SO_REUSEPORT, which this one does not.
func exclusiveAddress(_, _ string, _ syscall.RawConn) error { return nil }
