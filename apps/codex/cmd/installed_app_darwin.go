// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"os"
	"strings"
)

// installedAppBundle is CYFR.app in /Applications, where the CYFR app's
// DMG and its Homebrew cask put it.
const installedAppBundle = "/Applications/CYFR.app"

// installedAppPath is the installed app's executable inside its bundle.
func installedAppPath() (string, error) {
	return installedAppBundle + "/Contents/MacOS/CYFR", nil
}

// installedAppCyfr is the cyfr the app's bundle carries beside its
// executable (desktop/scripts/build.mjs's extraResources).
func installedAppCyfr() (string, error) {
	return installedAppBundle + "/Contents/Resources/cyfr", nil
}

// installedAppPresent is whether the bundle is there.
func installedAppPresent() bool {
	info, err := os.Stat(installedAppBundle)
	return err == nil && info.IsDir()
}

// appBundleOf is the app bundle holding the file at path, the path up to
// its .app folder whose Contents hold it, wherever the bundle lies; "" for
// a file no bundle holds. A file inside a bundle is the bundle's: changed
// or removed alone, it breaks the bundle's signature.
func appBundleOf(path string) string {
	if i := strings.Index(path, ".app/Contents/"); i >= 0 {
		return path[:i+len(".app")]
	}
	return ""
}
