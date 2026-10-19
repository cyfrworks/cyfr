// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build unix

package access

import (
	"os"
	"syscall"
	"testing"
)

// Serve's directory opens to the tailscale container, whose root holds no
// capability, whatever umask the person runs cyfr under.
func TestServeDirectoryIgnoresTheUmask(t *testing.T) {
	old := syscall.Umask(0o077)
	t.Cleanup(func() { syscall.Umask(old) })
	h := newHome(t)
	if err := h.e.closeServe(); err != nil {
		t.Fatal(err)
	}
	for name, want := range map[string]os.FileMode{h.e.path(serveDir): serveDirMode, h.e.servePath(): serveFileMode} {
		info, err := os.Stat(name)
		if err != nil {
			t.Fatal(err)
		}
		if got := info.Mode().Perm(); got != want {
			t.Errorf("%s is %v under umask 077, want %v", name, got, want)
		}
	}
}
