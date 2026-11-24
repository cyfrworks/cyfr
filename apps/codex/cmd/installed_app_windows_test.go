// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"golang.org/x/sys/windows"
)

// The installed app is under the account's local application folder as
// Windows answers it, which lies in the profile folder USERPROFILE names
// (this test binary's own home) and which LOCALAPPDATA does not move. Each
// answer Windows gives is logged, with and without its own check of the
// folder, before and after LOCALAPPDATA changes, so a red says which one
// moved.
func TestInstalledAppPathIsTheSystems(t *testing.T) {
	answers := func(when string) {
		for _, f := range []struct {
			name string
			flag uint32
		}{{"checked", windows.KF_FLAG_DEFAULT}, {"unchecked", windows.KF_FLAG_DONT_VERIFY}} {
			p, err := windows.KnownFolderPath(windows.FOLDERID_LocalAppData, f.flag)
			t.Logf("%s, %s: %q (%v)", when, f.name, p, err)
		}
	}
	answers("LOCALAPPDATA=" + os.Getenv("LOCALAPPDATA"))
	local, err := windows.KnownFolderPath(windows.FOLDERID_LocalAppData, windows.KF_FLAG_DONT_VERIFY)
	if err != nil {
		t.Fatal(err)
	}
	if profile := os.Getenv("USERPROFILE"); !strings.HasPrefix(strings.ToLower(local), strings.ToLower(profile)+`\`) {
		t.Errorf("the local application folder %q is not in the profile folder %q", local, profile)
	}
	want := filepath.Join(local, "Programs", "cyfr-desktop", "CYFR.exe")
	for _, elsewhere := range []string{t.TempDir(), `C:\nowhere\at\all`} {
		t.Setenv("LOCALAPPDATA", elsewhere)
		answers("LOCALAPPDATA=" + elsewhere)
		got, err := installedAppPath()
		if err != nil || got != want {
			t.Errorf("with LOCALAPPDATA=%s the installed app is %q (%v), want %q", elsewhere, got, err, want)
		}
		if strings.HasPrefix(strings.ToLower(got), strings.ToLower(elsewhere)) {
			t.Errorf("the installed app %q follows LOCALAPPDATA", got)
		}
	}
}
