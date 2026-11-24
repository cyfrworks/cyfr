// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import "testing"

// The installed app is CYFR.app in /Applications: its executable and the
// cyfr its bundle carries.
func TestInstalledAppPathIsTheSystems(t *testing.T) {
	if got, err := installedAppPath(); err != nil || got != "/Applications/CYFR.app/Contents/MacOS/CYFR" {
		t.Errorf("the installed app is %q (%v), want /Applications/CYFR.app/Contents/MacOS/CYFR", got, err)
	}
	if got, err := installedAppCyfr(); err != nil || got != "/Applications/CYFR.app/Contents/Resources/cyfr" {
		t.Errorf("the installed app's cyfr is %q (%v), want /Applications/CYFR.app/Contents/Resources/cyfr", got, err)
	}
}
