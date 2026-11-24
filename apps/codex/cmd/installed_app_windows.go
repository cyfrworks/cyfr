// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build windows

package cmd

import (
	"os"
	"path/filepath"
	"strings"

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

// installedAppCyfr is the cyfr the MSI installs beside the app, in its
// resources folder, which the MSI puts on the account's PATH.
func installedAppCyfr() (string, error) {
	app, err := installedAppPath()
	if err != nil {
		return "", err
	}
	return filepath.Join(filepath.Dir(app), "resources", "cyfr.exe"), nil
}

// installedAppPresent is whether the app's executable is there.
func installedAppPresent() bool {
	app, err := installedAppPath()
	if err != nil {
		return false
	}
	info, err := os.Stat(app)
	return err == nil && !info.IsDir()
}

// appBundleOf is the folder of the CYFR app holding the file at path, as
// the MSI lays it out wherever it lies: the file in a resources folder
// beside the app's CYFR.exe; "" otherwise. A cyfr there is the app's, its
// installer's to change or remove.
func appBundleOf(path string) string {
	dir := filepath.Dir(path)
	if !strings.EqualFold(filepath.Base(dir), "resources") {
		return ""
	}
	app := filepath.Dir(dir)
	if info, err := os.Stat(filepath.Join(app, "CYFR.exe")); err != nil || info.IsDir() {
		return ""
	}
	return app
}
