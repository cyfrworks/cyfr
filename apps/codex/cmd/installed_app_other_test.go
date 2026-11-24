// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build !darwin && !windows

package cmd

import (
	"os"
	"path/filepath"
	"testing"
)

// The installed app is where the cyfr-desktop package puts it: the app and
// the cyfr beside it.
func TestInstalledAppPathIsTheSystems(t *testing.T) {
	if got, err := installedAppPath(); err != nil || got != "/opt/cyfr/CYFR" {
		t.Errorf("the installed app is %q (%v), want /opt/cyfr/CYFR", got, err)
	}
	if got, err := installedAppCyfr(); err != nil || got != "/opt/cyfr/resources/cyfr" {
		t.Errorf("the installed app's cyfr is %q (%v), want /opt/cyfr/resources/cyfr", got, err)
	}
}

// The app is there while dpkg holds any record of its package but a
// removed one's, a dpkg left part way among them; no record, a removed
// package and package records that fail are no app.
func TestTheAppIsThereWhileDpkgHoldsItsPackage(t *testing.T) {
	for _, c := range []struct {
		name, dpkg string
		want       bool
	}{
		{"installed", "printf installed", true},
		{"left part way", "printf half-installed", true},
		{"unpacked, not configured", "printf unpacked", true},
		{"removed, its settings kept", "printf config-files", false},
		{"not installed", "printf not-installed", false},
		{"no record", "echo 'dpkg-query: no packages found matching cyfr-desktop' >&2; exit 1", false},
	} {
		t.Run(c.name, func(t *testing.T) {
			bin := t.TempDir()
			t.Setenv("PATH", bin)
			script := "#!/bin/sh\n[ \"$1 $2 $3 $4\" = '-W -f ${db:Status-Status} cyfr-desktop' ] || exit 9\n" + c.dpkg + "\n"
			if err := os.WriteFile(filepath.Join(bin, "dpkg-query"), []byte(script), 0o700); err != nil {
				t.Fatal(err)
			}
			if got := installedAppPresent(); got != c.want {
				t.Errorf("installedAppPresent = %v, want %v", got, c.want)
			}
		})
	}
}
