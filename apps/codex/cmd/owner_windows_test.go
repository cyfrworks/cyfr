// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import "io/fs"

// fileOwner is a file's owner, which Windows does not give as a uid.
func fileOwner(info fs.FileInfo) string { return "" }
