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
// the account's local application folder, as Windows answers it
// (FOLDERID_LocalAppData), never as an environment variable names it, in
// the folder the package's name names.
func installedAppPath() (string, error) {
	local, err := windows.KnownFolderPath(windows.FOLDERID_LocalAppData, windows.KF_FLAG_DEFAULT)
	if err != nil {
		return "", err
	}
	return filepath.Join(local, "Programs", "cyfr-desktop", "CYFR.exe"), nil
}
