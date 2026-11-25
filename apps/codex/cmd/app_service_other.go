// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build !linux

package cmd

// appUpdateService is Linux's alone: elsewhere no service installs the app.
func appUpdateService([]string) (int, bool) { return 0, false }
