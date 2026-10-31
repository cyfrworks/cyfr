// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build windows

package cmd

import "os"

// No root entry runs on Windows: automatic preparation is Linux's alone.
func ownedByRoot(os.FileInfo) bool { return false }
