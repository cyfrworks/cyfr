// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build !linux

package reach

// lockOwner names no holder where the kernel's lock table is not read.
func lockOwner(string) int { return 0 }
