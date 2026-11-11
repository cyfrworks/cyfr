// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build !windows

package cmd

import "golang.org/x/sys/unix"

// canReplaceIn reports whether this process may create, rename and remove
// entries in the directory dir and enter it, as the put-back does.
func canReplaceIn(dir string) error { return unix.Access(dir, unix.W_OK|unix.X_OK) }
