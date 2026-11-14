// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import "io"

// canReplaceIn is nil on Windows, whose engine (Docker Desktop) hands a
// bind mount's bytes to no other account than the person's.
func canReplaceIn(string) error { return nil }

// returnToSudoAccount does nothing on Windows, which has no sudo.
func returnToSudoAccount(*snapshotFiles, io.Writer) {}
