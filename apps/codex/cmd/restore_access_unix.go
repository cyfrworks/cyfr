// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build !windows

package cmd

import (
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"
	"syscall"

	"golang.org/x/sys/unix"
)

// canReplaceIn reports whether this process may create, rename and remove
// entries in the directory dir and enter it, as the put-back does.
func canReplaceIn(dir string) error { return unix.Access(dir, unix.W_OK|unix.X_OK) }

// What returnToSudoAccount reads of this process and the files, and how it
// changes an owner; tests stand in for them.
var (
	restoreEuid  = os.Geteuid
	restoreChown = os.Lchown
	// restoreOwner is the uid that owns the entry at path, not following
	// a link.
	restoreOwner = func(path string) (int, error) {
		info, err := os.Lstat(path)
		if err != nil {
			return 0, err
		}
		st, ok := info.Sys().(*syscall.Stat_t)
		if !ok {
			return 0, errors.New("no owner")
		}
		return int(st.Uid), nil
	}
)

// sudoAccount is the account sudo ran this process for, from SUDO_UID and
// SUDO_GID, when this process runs as root; ok is false otherwise, root's
// own login included.
func sudoAccount() (uid, gid int, ok bool) {
	if restoreEuid() != 0 {
		return 0, 0, false
	}
	uid, uerr := strconv.Atoi(os.Getenv("SUDO_UID"))
	gid, gerr := strconv.Atoi(os.Getenv("SUDO_GID"))
	if uerr != nil || gerr != nil || uid <= 0 || gid < 0 {
		return 0, 0, false
	}
	return uid, gid, true
}

// returnToSudoAccount gives the project files a restore run through sudo
// wrote back to the account that ran sudo, so the person's own commands
// read them afterwards: .env, docker-compose.yml, the scaffold files with
// the directories made for them, and the engine's state under .cyfr/, each
// entry root owns. The storage root and the database stay as the put-back
// left them: the image's entrypoint hands them to the image's user at the
// next start. An entry it cannot give back is said, and the restore's
// outcome stands.
func returnToSudoAccount(snap *snapshotFiles, errOut io.Writer) {
	uid, gid, ok := sudoAccount()
	if !ok {
		return
	}
	paths := []string{".env", "docker-compose.yml"}
	for _, name := range snap.manifest.Scaffold {
		for p := name; p != "." && p != string(filepath.Separator); p = filepath.Dir(p) {
			paths = append(paths, p)
		}
	}
	_ = filepath.WalkDir(".cyfr", func(p string, _ fs.DirEntry, err error) error {
		if err == nil {
			paths = append(paths, p)
		}
		return nil
	})
	seen := map[string]bool{}
	for _, p := range paths {
		if seen[p] {
			continue
		}
		seen[p] = true
		if owner, err := restoreOwner(p); err != nil || owner != 0 {
			continue
		}
		if err := restoreChown(p, uid, gid); err != nil {
			fmt.Fprintf(errOut, "Warning: %s is still root's (%v); give it back with: sudo chown %d:%d %s\n", p, err, uid, gid, p)
		}
	}
}
