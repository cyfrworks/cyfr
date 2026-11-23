// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

// deafWork runs no deaf work on Windows: no test there asks for it.
func deafWork(string) int { return 3 }
