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

	"github.com/cyfr/locus/keeper/internal/procfs"
)

// KeptRootMode is the mode the kept-homes root must have: sticky, and
// writable and searchable but not listable by the uids that make their
// disks in it, each as its own uid (Make); its owner (uid 0, the keeper,
// which lists it to draw a new disk's uid and keeps the disks' records in
// it) and its group, which no process the keeper starts holds, list it. No
// session reaches it, wherever it is: every space is given it covered, and
// holds of it only the path to a kept session's own home, with that disk's
// work folder at /work (package stage, Spec.KeptRoot).
const KeptRootMode = fs.ModeDir | fs.ModeSticky | 0o773

// KeptHomeMode is the mode every kept home has: its own uid's alone.
const KeptHomeMode = fs.ModeDir | 0o700

// MaxKeptUIDs bounds the size of the kept-home uid range.
const MaxKeptUIDs = 65536

// idPattern is a kept home's id: a login entry's id, a plain file name.
var idPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$`)

// Kept is the kept-homes root and the uid range its disks are owned by, as
// `--kept-homes <root>:<first>-<last>` names them. Each person has one disk
// under the root, owned by a uid of the range that no other disk holds, the
// disk's for its life, and each of their programs a kept home on it (disk.go).
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

// Contains reports whether uid is in the range.
func (k Kept) Contains(uid int) bool { return uid >= k.First && uid <= k.Last }

// ValidID reports whether id names a kept home.
func ValidID(id string) bool { return idPattern.MatchString(id) }

// Taken is every uid of the range that is not free for a new disk: the
// owner of any entry under the root, a disk or not (a home of a layout
// before the disks among them, whose uid is so never drawn), and any uid a process
// under procRoot (a /proc mount) holds (procfs.HeldUIDs). A root or a
// /proc that cannot be read takes them all, as an error.
func (k Kept) Taken(procRoot string) (map[int]bool, error) {
	entries, err := os.ReadDir(k.Root)
	if err != nil {
		return nil, err
	}
	held, err := procfs.HeldUIDs(procRoot)
	if err != nil {
		return nil, err
	}
	taken := map[int]bool{}
	for uid := range held {
		if k.Contains(uid) {
			taken[uid] = true
		}
	}
	for _, e := range entries {
		info, err := os.Lstat(filepath.Join(k.Root, e.Name()))
		if errors.Is(err, fs.ErrNotExist) {
			continue
		}
		if err != nil {
			return nil, err
		}
		if st, ok := info.Sys().(*syscall.Stat_t); ok && k.Contains(int(st.Uid)) {
			taken[int(st.Uid)] = true
		}
	}
	return taken, nil
}

// CheckKeptRoot verifies that root is a directory owned by uid 0 with
// KeptRootMode whose group no process the keeper starts holds (held): the
// group's bits give it a list of every kept home.
func CheckKeptRoot(root string, held func(gid int) bool) error {
	info, err := os.Lstat(root)
	if err != nil {
		return err
	}
	if info.Mode() != KeptRootMode {
		return fmt.Errorf("kept-homes root %s has mode %s, want %s", root, info.Mode(), KeptRootMode)
	}
	st, ok := info.Sys().(*syscall.Stat_t)
	if !ok || st.Uid != 0 {
		return fmt.Errorf("kept-homes root %s must be owned by uid 0", root)
	}
	if held(int(st.Gid)) {
		return fmt.Errorf("kept-homes root %s is of group %d, which a role, a pooled uid or a kept home holds", root, st.Gid)
	}
	return nil
}

// ErrNotKeptHome is a path that exists and is not a kept home of its uid.
var ErrNotKeptHome = errors.New("not a kept home")

// CheckKeptHome reports whether path is a made home of uid: a directory
// owned by uid with KeptHomeMode, read without following a symbolic link.
// An absent home is fs.ErrNotExist; anything else there is ErrNotKeptHome.
func CheckKeptHome(path string, uid int) error {
	return CheckOwnDir(path, uid, ErrNotKeptHome)
}

// CheckOwnDir reports whether path is a directory owned by uid with mode
// 0700 (KeptHomeMode), read without following a symbolic link: a kept home,
// or a role's run folder. An absent one is fs.ErrNotExist; anything else
// there is notOwn.
func CheckOwnDir(path string, uid int, notOwn error) error {
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	st, ok := info.Sys().(*syscall.Stat_t)
	if !ok || info.Mode() != KeptHomeMode || int(st.Uid) != uid {
		return fmt.Errorf("%s: %w", path, notOwn)
	}
	return nil
}
