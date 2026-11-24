// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"path/filepath"
	"strings"
	"testing"

	"golang.org/x/sys/windows"
)

// The installed app is under the account's local application folder as
// Windows answers it, whatever LOCALAPPDATA names.
func TestInstalledAppPathIsTheSystems(t *testing.T) {
	elsewhere := t.TempDir()
	t.Setenv("LOCALAPPDATA", elsewhere)
	local, err := windows.KnownFolderPath(windows.FOLDERID_LocalAppData, windows.KF_FLAG_DEFAULT)
	if err != nil {
		t.Fatal(err)
	}
	got, err := installedAppPath()
	if want := filepath.Join(local, "Programs", "cyfr-desktop", "CYFR.exe"); err != nil || got != want {
		t.Errorf("the installed app is %q (%v), want %q", got, err, want)
	}
	if strings.HasPrefix(strings.ToLower(got), strings.ToLower(elsewhere)) {
		t.Errorf("the installed app %q follows LOCALAPPDATA", got)
	}
}
