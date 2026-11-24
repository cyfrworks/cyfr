// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build !darwin && !windows

package cmd

// installedAppPath is where the cyfr-desktop package puts the app.
func installedAppPath() (string, error) {
	return "/opt/cyfr/CYFR", nil
}
