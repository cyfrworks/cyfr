// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package home

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
)

// KeptRootMode is the mode the kept-homes root must have: sticky, and
// writable and searchable but not listable by the uids that make their homes
// in it; its owner (uid 0, the keeper) and its group (the client's) list it,
// the client to draw a free uid for a new home.
const KeptRootMode = fs.ModeDir | fs.ModeSticky | 0o773

// KeptHomeMode is the mode every kept home has: its own uid's alone.
const KeptHomeMode = fs.ModeDir | 0o700

// MaxKeptUIDs bounds the size of the kept-home uid range.
const MaxKeptUIDs = 65536

// idPattern is a kept home's id: a login entry's id, a plain file name.
var idPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$`)

// Kept is the kept-homes root and the uid range its homes are owned by, as
// `--kept-homes <root>:<first>-<last>` names them. A kept home is
// `<root>/<id>`, 0700, owned by a uid of the range that no other home holds
// while it lives; the uid is the home's for the home's life.
type Kept struct {
	Root  string
	First int
	Last  int
}

// ParseKept reads `<root>:<first>-<last>`: a clean absolute root other than
// "/", and a range of at most MaxKeptUIDs uids from 1 to 2^31-1.
func ParseKept(value string) (Kept, error) {
	root, ids, ok := strings.Cut(value, ":")
	if !ok {
		return Kept{}, fmt.Errorf("kept homes %q are not <root>:<first>-<last>", value)
	}
	if !filepath.IsAbs(root) || filepath.Clean(root) != root || root == "/" {
		return Kept{}, fmt.Errorf("kept-homes root %q must be a clean absolute path other than /", root)
	}
	a, b, ok := strings.Cut(ids, "-")
	first, errA := strconv.Atoi(a)
	last, errB := strconv.Atoi(b)
	switch {
	case !ok || errA != nil || errB != nil:
		return Kept{}, fmt.Errorf("kept-home uids %q are not <first>-<last>", ids)
	case first < 1 || last >= 1<<31 || first > last:
		return Kept{}, fmt.Errorf("kept-home uids %d-%d must rise from 1 to below 2^31", first, last)
	case last-first+1 > MaxKeptUIDs:
		return Kept{}, fmt.Errorf("kept-home uids %d-%d name more than %d", first, last, MaxKeptUIDs)
	}
	return Kept{Root: root, First: first, Last: last}, nil
}

// String is the flag's value, which the client is handed as KEEPER_KEPT_HOMES.
func (k Kept) String() string {
	return k.Root + ":" + strconv.Itoa(k.First) + "-" + strconv.Itoa(k.Last)
}

// Contains reports whether uid is in the range.
func (k Kept) Contains(uid int) bool { return uid >= k.First && uid <= k.Last }

// ValidID reports whether id names a kept home.
func ValidID(id string) bool { return idPattern.MatchString(id) }

// Validate checks that path is a kept home's: directly under the root,
// named by a valid id, and that uid is the range's.
func (k Kept) Validate(path string, uid int) error {
	if filepath.Clean(path) != path || filepath.Dir(path) != k.Root || !ValidID(filepath.Base(path)) {
		return fmt.Errorf("kept home %q is not a home directly under %s", path, k.Root)
	}
	if !k.Contains(uid) {
		return fmt.Errorf("uid %d is outside the kept-home range %d-%d", uid, k.First, k.Last)
	}
	return nil
}

// CheckKeptRoot verifies that root is a directory owned by uid 0 and the
// group gid, with KeptRootMode.
func CheckKeptRoot(root string, gid int) error {
	info, err := os.Lstat(root)
	if err != nil {
		return err
	}
	if info.Mode() != KeptRootMode {
		return fmt.Errorf("kept-homes root %s has mode %s, want %s", root, info.Mode(), KeptRootMode)
	}
	st, ok := info.Sys().(*syscall.Stat_t)
	if !ok || st.Uid != 0 || int(st.Gid) != gid {
		return fmt.Errorf("kept-homes root %s must be owned by uid 0 and the client's group %d", root, gid)
	}
	return nil
}

// ErrNotKeptHome is a path that exists and is not a kept home of its uid.
var ErrNotKeptHome = errors.New("not a kept home")

// CheckKeptHome reports whether path is a made home of uid: a directory
// owned by uid with KeptHomeMode, read without following a symbolic link.
// An absent home is fs.ErrNotExist; anything else there is ErrNotKeptHome.
func CheckKeptHome(path string, uid int) error {
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	st, ok := info.Sys().(*syscall.Stat_t)
	if !ok || info.Mode() != KeptHomeMode || int(st.Uid) != uid {
		return fmt.Errorf("%s: %w", path, ErrNotKeptHome)
	}
	return nil
}
