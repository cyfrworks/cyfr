// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package home names, checks and removes the per-spawn home directories
// under the home root. A home is `<root>/<uid>-<32 hex digits>`, created
// 0700 by the spawned uid itself and removed by that uid at retirement.
package home

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"syscall"

	"golang.org/x/sys/unix"
)

// RootMode is the mode the home root must have: sticky, and writable and
// searchable but not listable by the pool uids.
const RootMode = fs.ModeDir | fs.ModeSticky | 0o733

var namePattern = regexp.MustCompile(`^([1-9][0-9]{0,9})-[0-9a-f]{32}$`)

// NewName returns a fresh home name for uid with 128 random bits.
func NewName(uid int) (string, error) {
	var nonce [16]byte
	if _, err := rand.Read(nonce[:]); err != nil {
		return "", err
	}
	return strconv.Itoa(uid) + "-" + hex.EncodeToString(nonce[:]), nil
}

// Validate checks that home is a direct child of root named for uid.
func Validate(root, home string, uid int) error {
	if !filepath.IsAbs(root) || filepath.Clean(root) != root {
		return fmt.Errorf("home root %q must be a clean absolute path", root)
	}
	if filepath.Clean(home) != home || filepath.Dir(home) != root {
		return fmt.Errorf("home %q must be directly under %s", home, root)
	}
	m := namePattern.FindStringSubmatch(filepath.Base(home))
	if m == nil || m[1] != strconv.Itoa(uid) {
		return fmt.Errorf("home %q is not named for uid %d", home, uid)
	}
	return nil
}

// CheckRoot verifies that root is a directory owned by uid 0 with RootMode.
func CheckRoot(root string) error {
	info, err := os.Lstat(root)
	if err != nil {
		return err
	}
	if info.Mode() != RootMode {
		return fmt.Errorf("home root %s has mode %s, want %s (a tmpfs mounted with mode=1733)", root, info.Mode(), RootMode)
	}
	if st, ok := info.Sys().(*syscall.Stat_t); !ok || st.Uid != 0 {
		return fmt.Errorf("home root %s must be owned by uid 0", root)
	}
	return nil
}

// Remove deletes home and everything under it. It works through descriptors
// of the home and its subdirectories, never opening the home root, which the
// pool uids may not read, and restores the owner's permission on each
// directory before emptying it. A home that does not exist is already
// removed. It refuses a home that is not a directory owned by uid.
func Remove(home string, uid int) error {
	info, err := os.Lstat(home)
	if errors.Is(err, fs.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	st, ok := info.Sys().(*syscall.Stat_t)
	if !info.IsDir() || !ok || int(st.Uid) != uid {
		return fmt.Errorf("home %s is not a directory owned by uid %d", home, uid)
	}
	if err := os.Chmod(home, 0o700); err != nil {
		return err
	}
	fd, err := unix.Open(home, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
	if err != nil {
		return fmt.Errorf("open %s: %w", home, err)
	}
	err = removeContents(fd)
	unix.Close(fd)
	if err != nil {
		return fmt.Errorf("empty %s: %w", home, err)
	}
	return unix.Rmdir(home)
}

// removeContents removes every entry of the directory open as dirfd.
func removeContents(dirfd int) error {
	dup, err := unix.Dup(dirfd)
	if err != nil {
		return err
	}
	dir := os.NewFile(uintptr(dup), "dir")
	names, err := dir.Readdirnames(-1)
	dir.Close()
	if err != nil {
		return err
	}
	for _, name := range names {
		err := unix.Unlinkat(dirfd, name, 0)
		if err == nil || errors.Is(err, unix.ENOENT) {
			continue
		}
		// unlink refuses a directory: EISDIR on Linux, EPERM elsewhere.
		if !errors.Is(err, unix.EISDIR) && !errors.Is(err, unix.EPERM) {
			return fmt.Errorf("%s: %w", name, err)
		}
		_ = unix.Fchmodat(dirfd, name, 0o700, 0)
		child, err := unix.Openat(dirfd, name, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
		if err != nil {
			return fmt.Errorf("%s: %w", name, err)
		}
		err = removeContents(child)
		unix.Close(child)
		if err != nil {
			return fmt.Errorf("%s/%w", name, err)
		}
		if err := unix.Unlinkat(dirfd, name, unix.AT_REMOVEDIR); err != nil {
			return fmt.Errorf("%s: %w", name, err)
		}
	}
	return nil
}
