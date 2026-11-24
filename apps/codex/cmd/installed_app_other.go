// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build !darwin && !windows

package cmd

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// installedAppPath is where the cyfr-desktop package puts the app.
func installedAppPath() (string, error) {
	return "/opt/cyfr/CYFR", nil
}

// installedAppCyfr is the cyfr the package carries beside the app
// (desktop/scripts/build.mjs's extraResources), which it links as
// /usr/bin/cyfr.
func installedAppCyfr() (string, error) {
	return "/opt/cyfr/resources/cyfr", nil
}

// installedAppPresent is whether dpkg holds any record of the app's
// package but a removed one's: installed, or left part way by a dpkg that
// did not finish, which the package tool's next install mends.
func installedAppPresent() bool {
	out, err := exec.Command("dpkg-query", "-W", "-f", "${db:Status-Status}", appPackage).Output()
	status := strings.TrimSpace(string(out))
	return err == nil && status != "" && status != "not-installed" && status != "config-files"
}

// appBundleOf is the folder of the CYFR app holding the file at path, as
// the app's packaging lays it out wherever it lies: the file in a
// resources folder beside the app's CYFR executable; "" otherwise. A cyfr
// there is the app's, its package's to change or remove.
func appBundleOf(path string) string {
	dir := filepath.Dir(path)
	if filepath.Base(dir) != "resources" {
		return ""
	}
	app := filepath.Dir(dir)
	if info, err := os.Stat(filepath.Join(app, "CYFR")); err != nil || info.IsDir() {
		return ""
	}
	return app
}
