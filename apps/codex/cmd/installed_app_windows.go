// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build windows

package cmd

import (
	"path/filepath"

	"golang.org/x/sys/windows"
)

// installedAppPath is where the CYFR installer puts the app for this
// account (its per-user MSI, apps/codex/desktop/scripts/build.mjs): under
// the account's local application folder as Windows answers it
// (FOLDERID_LocalAppData), in the folder the package's name names. Windows
// answers that folder from the account's profile folder as USERPROFILE
// names it, and LOCALAPPDATA changes nothing of it: whoever can set either
// for the person's shell already runs as them. Windows is not asked to
// check the folder is there: whether the app is, its caller's look decides.
func installedAppPath() (string, error) {
	local, err := windows.KnownFolderPath(windows.FOLDERID_LocalAppData, windows.KF_FLAG_DONT_VERIFY)
	if err != nil {
		return "", err
	}
	return filepath.Join(local, "Programs", "cyfr-desktop", "CYFR.exe"), nil
}
