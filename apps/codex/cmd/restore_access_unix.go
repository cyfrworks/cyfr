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
	"regexp"
	"strconv"
	"strings"

	"golang.org/x/sys/unix"
)

// canReplaceIn reports whether this process may create, rename and remove
// entries in the directory dir and enter it, as the put-back does.
func canReplaceIn(dir string) error { return unix.Access(dir, unix.W_OK|unix.X_OK) }

// What returnToSudoAccount reads of this process and the files, and how it
// changes an owner; tests stand in for them. Both file calls act on the
// entry name in the directory dirfd, never following a link; path is the
// entry's path in the project, for what is said.
var (
	restoreEuid    = os.Geteuid
	restoreOwnerAt = func(dirfd int, name, path string) (int, error) {
		var st unix.Stat_t
		if err := unix.Fstatat(dirfd, name, &st, unix.AT_SYMLINK_NOFOLLOW); err != nil {
			return 0, err
		}
		return int(st.Uid), nil
	}
	restoreChownAt = func(dirfd int, name, path string, uid, gid int) error {
		return unix.Fchownat(dirfd, name, uid, gid, unix.AT_SYMLINK_NOFOLLOW)
	}
)

// sudoID is the form sudo writes SUDO_UID and SUDO_GID in: decimal digits
// alone, no sign, space or base.
var sudoID = regexp.MustCompile(`^[0-9]{1,10}$`)

// sudoAccount is the account sudo ran this process for, from SUDO_UID and
// SUDO_GID, when this process runs as root: ok is false, with no error,
// for a process that is not root and for root's own login, which sets
// neither, and with the refusal for a value that is not sudo's form.
func sudoAccount() (uid, gid int, ok bool, err error) {
	if restoreEuid() != 0 {
		return 0, 0, false, nil
	}
	rawUID, rawGID := os.Getenv("SUDO_UID"), os.Getenv("SUDO_GID")
	if rawUID == "" && rawGID == "" {
		return 0, 0, false, nil
	}
	if !sudoID.MatchString(rawUID) || !sudoID.MatchString(rawGID) {
		return 0, 0, false, fmt.Errorf("SUDO_UID and SUDO_GID must each be a plain decimal number, and they are %q and %q", rawUID, rawGID)
	}
	uid, uerr := strconv.Atoi(rawUID)
	gid, gerr := strconv.Atoi(rawGID)
	if uerr != nil || gerr != nil {
		return 0, 0, false, fmt.Errorf("SUDO_UID and SUDO_GID must each be a plain decimal number, and they are %q and %q", rawUID, rawGID)
	}
	// sudo run by root names root, who owns the files already.
	return uid, gid, uid != 0, nil
}

// returnToSudoAccount gives the project files a restore run through sudo
// wrote back to the account that ran sudo, so the person's own commands
// read them afterwards: .env, docker-compose.yml, the scaffold files with
// the directories made for them, and the engine's state under .cyfr/, each
// entry root owns. The storage root and the database stay as the put-back
// left them: the image's entrypoint hands them to the image's user at the
// next start. Nothing is given back through a link, at any level of its
// path, so no entry outside the project changes owner. What is not given
// back is said, and the restore's outcome stands.
func returnToSudoAccount(snap *snapshotFiles, errOut io.Writer) {
	uid, gid, ok, err := sudoAccount()
	if err != nil {
		fmt.Fprintf(errOut, "Warning: %v, so nothing the restore wrote was given back to the account that ran sudo.\n", err)
		return
	}
	if !ok {
		return
	}
	paths := []string{".env", "docker-compose.yml"}
	for _, name := range snap.manifest.Scaffold {
		for p := name; p != "." && p != string(filepath.Separator); p = filepath.Dir(p) {
			paths = append(paths, p)
		}
	}
	// WalkDir lists a link without entering it.
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
		err := chownInProject(p, uid, gid)
		switch {
		case errors.Is(err, errThroughLink):
			fmt.Fprintf(errOut, "Warning: %s was not given back to the account that ran sudo: %v.\n", p, err)
		case err != nil:
			fmt.Fprintf(errOut, "Warning: %s is still root's (%v); give it back with: sudo chown -h %d:%d %s\n", p, err, uid, gid, p)
		}
	}
}

// errThroughLink refuses an entry whose path crosses a link.
var errThroughLink = errors.New("its path crosses a link, and nothing is given back through one")

// chownInProject gives the entry at the project-relative path p to uid
// and gid when root owns it, opening each directory of the path in the one
// before it without following a link, so neither a link in the path nor
// one swapped in meanwhile leads outside the project. An entry that does
// not exist is no failure.
func chownInProject(p string, uid, gid int) error {
	parts := strings.Split(filepath.ToSlash(filepath.Clean(p)), "/")
	dirfd, err := unix.Open(".", unix.O_RDONLY|unix.O_DIRECTORY|unix.O_CLOEXEC, 0)
	if err != nil {
		return err
	}
	defer func() { unix.Close(dirfd) }()
	for _, dir := range parts[:len(parts)-1] {
		next, err := unix.Openat(dirfd, dir, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
		switch {
		case errors.Is(err, unix.ENOENT):
			return nil
		case errors.Is(err, unix.ELOOP) || errors.Is(err, unix.ENOTDIR):
			return errThroughLink
		case err != nil:
			return err
		}
		unix.Close(dirfd)
		dirfd = next
	}
	name := parts[len(parts)-1]
	owner, err := restoreOwnerAt(dirfd, name, p)
	switch {
	case errors.Is(err, unix.ENOENT):
		return nil
	case err != nil:
		return err
	case owner != 0:
		return nil
	}
	return restoreChownAt(dirfd, name, p, uid, gid)
}
