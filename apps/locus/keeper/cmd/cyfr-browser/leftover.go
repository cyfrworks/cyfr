// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

import (
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
)

// leftovers are what the driver's fetch of Chrome for Testing wrote in a
// browser's home before the image carried the browser: one folder, which
// held the fetched versions, the last check's record, the lock and any
// partial download or staging folder. The profile is the home's chrome
// folder, apart from it.
var leftovers = []string{"cyfr-browser"}

// removeLeftovers removes each of leftovers from home: a folder with what
// it holds, anything else, a symlink among it, as itself, never followed.
// Nothing else of the home is read or removed, and a home holding none of
// them is left as it is. A removal that fails is said once on log, and
// the next start tries again; it never stops the browser.
func removeLeftovers(home string, log io.Writer) {
	for _, name := range leftovers {
		path := filepath.Join(home, name)
		info, err := os.Lstat(path)
		switch {
		case errors.Is(err, fs.ErrNotExist):
			continue
		case err != nil:
		case info.IsDir():
			err = os.RemoveAll(path)
		default:
			err = os.Remove(path)
		}
		if err != nil {
			fmt.Fprintf(log, "cyfr-browser: the Chrome an earlier version fetched is not removed yet: %v\n", err)
		}
	}
}
