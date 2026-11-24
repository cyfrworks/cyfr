// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build !darwin && !windows

package cmd

import "testing"

// The installed app is where the cyfr-desktop package puts it.
func TestInstalledAppPathIsTheSystems(t *testing.T) {
	if got, err := installedAppPath(); err != nil || got != "/opt/cyfr/CYFR" {
		t.Errorf("the installed app is %q (%v), want /opt/cyfr/CYFR", got, err)
	}
}
