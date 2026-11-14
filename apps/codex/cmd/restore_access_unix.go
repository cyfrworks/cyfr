// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build !windows

package cmd

import (
	"crypto/rand"
	"encoding/hex"
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
			fmt.Fprintf(errOut, "Warning: %s was not given back to the account that ran sudo: its path %v.\n", p, err)
		case err != nil:
			fmt.Fprintf(errOut, "Warning: %s is still root's (%v); give it back with: sudo chown -h %d:%d %s\n", p, err, uid, gid, p)
		}
	}
}

// errThroughLink refuses an entry whose path crosses a link.
var errThroughLink = errors.New("crosses a link, which nothing is written or given back through")

// projectDir opens the project's directory dir, a path relative to the
// project, each directory of it opened in the one before it without
// following a link, so neither a link in the path nor one swapped in
// meanwhile leads outside the project; with create, a missing directory
// is made, mode 0755 as scaffold.MakeDir makes it. A path that crosses a
// link answers errThroughLink; a missing directory without create answers
// unix.ENOENT. The caller closes the descriptor.
func projectDir(dir string, create bool) (int, error) {
	dirfd, err := unix.Open(".", unix.O_RDONLY|unix.O_DIRECTORY|unix.O_CLOEXEC, 0)
	if err != nil {
		return -1, err
	}
	clean := filepath.ToSlash(filepath.Clean(dir))
	if clean == "." {
		return dirfd, nil
	}
	for _, part := range strings.Split(clean, "/") {
		made := false
		if create {
			switch err := unix.Mkdirat(dirfd, part, 0o755); {
			case err == nil:
				made = true
			case !errors.Is(err, unix.EEXIST):
				unix.Close(dirfd)
				return -1, err
			}
		}
		next, err := unix.Openat(dirfd, part, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
		unix.Close(dirfd)
		switch {
		case errors.Is(err, unix.ELOOP) || errors.Is(err, unix.ENOTDIR):
			return -1, errThroughLink
		case err != nil:
			return -1, err
		}
		if made {
			if err := unix.Fchmod(next, 0o755); err != nil {
				unix.Close(next)
				return -1, err
			}
		}
		dirfd = next
	}
	return dirfd, nil
}

// noLinkIn reports errThroughLink when the project's directory dir, or a
// directory on its way, is a link; one that does not exist yet is none.
func noLinkIn(dir string) error {
	dirfd, err := projectDir(dir, false)
	if errors.Is(err, unix.ENOENT) {
		return nil
	}
	if err != nil {
		return err
	}
	unix.Close(dirfd)
	return nil
}

// putProjectFile writes data over the project's file name, mode, through
// a synced temporary file beside it renamed into place, as
// scaffold.ReplaceFile does, but in the directory projectDir opened: nothing
// is written through a link, and a link at name itself is replaced.
func putProjectFile(name string, data []byte, mode os.FileMode) error {
	dirfd, err := projectDir(filepath.Dir(name), true)
	if err != nil {
		return err
	}
	defer unix.Close(dirfd)
	var suffix [8]byte
	if _, err := rand.Read(suffix[:]); err != nil {
		return err
	}
	base := filepath.Base(name)
	tmp := "." + base + ".scaffold-" + hex.EncodeToString(suffix[:])
	fd, err := unix.Openat(dirfd, tmp, unix.O_WRONLY|unix.O_CREAT|unix.O_EXCL|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0o600)
	if err != nil {
		return err
	}
	f := os.NewFile(uintptr(fd), tmp)
	_, err = f.Write(data)
	if err = errors.Join(err, f.Chmod(mode), f.Sync(), f.Close()); err == nil {
		err = unix.Renameat(dirfd, tmp, dirfd, base)
	}
	if err != nil {
		unix.Unlinkat(dirfd, tmp, 0)
	}
	return err
}

// removeProjectFile removes the project's file name, in the directory
// projectDir opened; one that is not there is no failure.
func removeProjectFile(name string) error {
	dirfd, err := projectDir(filepath.Dir(name), false)
	if errors.Is(err, unix.ENOENT) {
		return nil
	}
	if err != nil {
		return err
	}
	defer unix.Close(dirfd)
	if err := unix.Unlinkat(dirfd, filepath.Base(name), 0); err != nil && !errors.Is(err, unix.ENOENT) {
		return err
	}
	return nil
}

// chownInProject gives the entry at the project-relative path p to uid
// and gid when root owns it, in the directory projectDir opened, without
// following a link at p itself. An entry that does not exist is no
// failure.
func chownInProject(p string, uid, gid int) error {
	dirfd, err := projectDir(filepath.Dir(p), false)
	if errors.Is(err, unix.ENOENT) {
		return nil
	}
	if err != nil {
		return err
	}
	defer unix.Close(dirfd)
	name := filepath.Base(p)
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
