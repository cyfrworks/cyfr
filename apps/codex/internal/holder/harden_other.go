// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build !linux

package holder

// HardenProcess does nothing outside Linux.
func HardenProcess() error { return nil }
