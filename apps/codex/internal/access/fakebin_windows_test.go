// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build windows

package access

// On Windows a docker child holds no lock descriptor and its group is
// its job's.
func ownGroupNow() bool            { return false }
func lockFDIsLock(dir string) bool { return false }
