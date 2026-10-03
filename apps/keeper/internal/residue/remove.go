// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package residue

import (
	"errors"
	"fmt"
	"path/filepath"
	"strings"

	"golang.org/x/sys/unix"
)

// RemovePath removes path and everything below it, with the calling
// process's permissions, which are the uid's own. The parent directory is
// reached one component at a time without following a symbolic link, the
// entry must be owned by uid, and each directory is made readable,
// writable and searchable by its owner before it is emptied. A path that no
// longer exists is already removed.
func RemovePath(path string, uid int) error {
	if !cleanAbs(path) {
		return fmt.Errorf("%q is not a clean absolute path", path)
	}
	parent, err := openDir(filepath.Dir(path))
	if err != nil {
		if errors.Is(err, unix.ENOENT) {
			return nil
		}
		return fmt.Errorf("%s: %w", filepath.Dir(path), err)
	}
	defer unix.Close(parent)
	name := filepath.Base(path)
	var st unix.Stat_t
	if err := unix.Fstatat(parent, name, &st, unix.AT_SYMLINK_NOFOLLOW); err != nil {
		if errors.Is(err, unix.ENOENT) {
			return nil
		}
		return fmt.Errorf("%s: %w", path, err)
	}
	if int(st.Uid) != uid {
		return fmt.Errorf("%s is owned by uid %d, not %d", path, st.Uid, uid)
	}
	if err := removeEntry(parent, name, uint32(st.Mode)&unix.S_IFMT == unix.S_IFDIR); err != nil {
		return fmt.Errorf("%s: %w", path, err)
	}
	return nil
}

// RemoveQueues unlinks the named message queues from the mqueue mount dir.
func RemoveQueues(dir string, names []string) error {
	fd, err := unix.Open(dir, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
	if err != nil {
		return fmt.Errorf("%s: %w", dir, err)
	}
	defer unix.Close(fd)
	var errs []error
	for _, name := range names {
		if err := unix.Unlinkat(fd, name, 0); err != nil && !errors.Is(err, unix.ENOENT) {
			errs = append(errs, fmt.Errorf("queue %s: %w", name, err))
		}
	}
	return errors.Join(errs...)
}

// openDir opens a directory for use as the base of *at calls, walking from
// "/" without following a symbolic link in any component.
func openDir(path string) (int, error) {
	fd, err := unix.Open("/", dirFlags, 0)
	if err != nil {
		return -1, err
	}
	for _, component := range strings.Split(strings.TrimPrefix(path, "/"), "/") {
		if component == "" {
			continue
		}
		next, err := unix.Openat(fd, component, dirFlags, 0)
		unix.Close(fd)
		if err != nil {
			return -1, err
		}
		fd = next
	}
	return fd, nil
}

// removeEntry removes the entry name of the directory open as dirfd.
func removeEntry(dirfd int, name string, isDir bool) error {
	if !isDir {
		err := unix.Unlinkat(dirfd, name, 0)
		if err == nil || errors.Is(err, unix.ENOENT) {
			return nil
		}
		// unlink refuses a directory: EISDIR on Linux, EPERM elsewhere. The
		// entry was replaced by one after it was examined.
		if !errors.Is(err, unix.EISDIR) && !errors.Is(err, unix.EPERM) {
			return err
		}
	}
	_ = unix.Fchmodat(dirfd, name, 0o700, 0)
	child, err := unix.Openat(dirfd, name, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
	if err != nil {
		if errors.Is(err, unix.ENOENT) {
			return nil
		}
		return err
	}
	err = removeContents(child)
	unix.Close(child)
	if err != nil {
		return err
	}
	if err := unix.Unlinkat(dirfd, name, unix.AT_REMOVEDIR); err != nil && !errors.Is(err, unix.ENOENT) {
		return err
	}
	return nil
}

// removeContents removes every entry of the directory open as dirfd.
func removeContents(dirfd int) error {
	names, err := readNames(dirfd)
	if err != nil {
		return err
	}
	for _, name := range names {
		var st unix.Stat_t
		if err := unix.Fstatat(dirfd, name, &st, unix.AT_SYMLINK_NOFOLLOW); err != nil {
			if errors.Is(err, unix.ENOENT) {
				continue
			}
			return fmt.Errorf("%s: %w", name, err)
		}
		if err := removeEntry(dirfd, name, uint32(st.Mode)&unix.S_IFMT == unix.S_IFDIR); err != nil {
			return fmt.Errorf("%s/%w", name, err)
		}
	}
	return nil
}
