// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package shell

import "testing"

// OpenForTest is a shell set up and open at this package's stand-in CYFR,
// hiding its screen through restart, for tests outside the package; told
// is how many sessions that CYFR has heard locked.
func OpenForTest(t *testing.T, restart func()) (sh *Shell, told func() int) {
	t.Helper()
	home := newFakeHome(t)
	b := newBox(t, home, t.TempDir())
	setUpAndOpen(t, home, b)
	b.shell.cfg.Restart = restart
	return b.shell, func() int {
		home.mu.Lock()
		defer home.mu.Unlock()
		return len(home.locked)
	}
}
