// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

// installedAppPath is where the CYFR app's DMG puts it: CYFR.app in
// /Applications, its executable inside the bundle.
func installedAppPath() (string, error) {
	return "/Applications/CYFR.app/Contents/MacOS/CYFR", nil
}
