// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import "testing"

// The installed app is CYFR.app's executable in /Applications.
func TestInstalledAppPathIsTheSystems(t *testing.T) {
	if got, err := installedAppPath(); err != nil || got != "/Applications/CYFR.app/Contents/MacOS/CYFR" {
		t.Errorf("the installed app is %q (%v), want /Applications/CYFR.app/Contents/MacOS/CYFR", got, err)
	}
}
