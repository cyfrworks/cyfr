// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build unix

package scaffold

import (
	"os"
	"syscall"
	"testing"
)

// An extracted file keeps the tarball's mode whatever umask cyfr init
// runs under, so a container whose root holds no capability, caddy
// reading its Caddyfile, can still read it.
func TestExtractedFilesKeepTheirModeUnderAnyUmask(t *testing.T) {
	old := syscall.Umask(0o077)
	t.Cleanup(func() { syscall.Umask(old) })
	sc := readSignedChecksums(t)
	serveScaffold(t, sc, sc.version, signedAssets(sc))
	if err := Download(sc.version); err != nil {
		t.Fatalf("Download: %v", err)
	}
	for _, name := range []string{"configuration-guide.md", "docker-compose.yml"} {
		info, err := os.Stat(name)
		if err != nil {
			t.Fatal(err)
		}
		if got := info.Mode().Perm(); got&0o044 != 0o044 {
			t.Errorf("%s is %v under umask 077; others and the group cannot read it", name, got)
		}
	}
}
