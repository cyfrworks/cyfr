// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

// Package homepath is the one way down a person's folder for what a brain
// driver or a program's fetch creates, reads or removes there: from a root
// (the home, or a folder its program is told to keep its files in), each
// folder on the way is opened by its name in the last one (openat), never
// through a link (O_NOFOLLOW, O_DIRECTORY), and must be a folder of this
// user's own; the last component is opened the same way, so a link there
// is never followed either. What is not what it should be is refused with
// ErrNotOwn or ErrNotOwnFile, and nothing is read, written or removed
// through it. Every descriptor is close-on-exec, so a program the caller
// starts holds none.
package homepath

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"

	"golang.org/x/sys/unix"
)

var (
	// ErrNotOwn is a folder on the way that is a link, no folder, or not
	// this user's own.
	ErrNotOwn = errors.New("is a link or not a folder of this user's own")
	// ErrNotOwnFile is a last component that is a link, or a file that is
	// not a regular file of this user's own.
	ErrNotOwnFile = errors.New("is a link or not a file of this user's own")
)

// Absent is an error that says a component of the way does not exist.
func Absent(err error) bool { return errors.Is(err, fs.ErrNotExist) }

// Refused is an error that says something on the way is not what it should
// be.
func Refused(err error) bool { return errors.Is(err, ErrNotOwn) || errors.Is(err, ErrNotOwnFile) }

// Dir is an open folder reached so.
type Dir struct {
	f *os.File
}

func failed(op, path string, err error) error { return &fs.PathError{Op: op, Path: path, Err: err} }

// own says the descriptor is of the kind wanted and this user's own.
func own(fd int, dir bool) bool {
	var st unix.Stat_t
	if unix.Fstat(fd, &st) != nil || st.Uid != uint32(os.Getuid()) {
		return false
	}
	if dir {
		return st.Mode&unix.S_IFMT == unix.S_IFDIR
	}
	return st.Mode&unix.S_IFMT == unix.S_IFREG
}

// Root opens the folder a way starts from, which must be a folder of this
// user's own.
func Root(root string) (*Dir, error) {
	fd, err := unix.Open(root, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_CLOEXEC, 0)
	if err != nil {
		return nil, failed("open", root, err)
	}
	if !own(fd, true) {
		unix.Close(fd)
		return nil, failed("open", root, ErrNotOwn)
	}
	return &Dir{f: os.NewFile(uintptr(fd), root)}, nil
}

// Walk opens the folder `rel` under root, each step as Folder does, making
// a missing one 0700 when `create` is set.
func Walk(root, rel string, create bool) (*Dir, error) {
	d, err := Root(root)
	if err != nil {
		return nil, err
	}
	for _, name := range steps(rel) {
		next, err := d.Folder(name, create)
		d.Close()
		if err != nil {
			return nil, err
		}
		d = next
	}
	return d, nil
}

func steps(rel string) []string {
	var out []string
	for _, s := range strings.Split(filepath.ToSlash(rel), "/") {
		if s != "" && s != "." {
			out = append(out, s)
		}
	}
	return out
}

// plain is a name of one component.
func plain(name string) bool {
	return name != "" && name != "." && name != ".." && !strings.Contains(name, "/")
}

func (d *Dir) fd() int { return int(d.f.Fd()) }

// Path is the folder's path, for a program to be told and for words.
func (d *Dir) Path() string { return d.f.Name() }

// Fd is the folder's descriptor, for a lock on it.
func (d *Dir) Fd() uintptr { return d.f.Fd() }

func (d *Dir) Close() error { return d.f.Close() }

func (d *Dir) join(name string) string { return filepath.Join(d.Path(), name) }

// Folder opens the folder `name` in d, never through a link, made 0700
// first when missing and `create` is set, and refuses it unless it is a
// folder of this user's own.
func (d *Dir) Folder(name string, create bool) (*Dir, error) {
	if !plain(name) {
		return nil, failed("open", d.join(name), ErrNotOwn)
	}
	if create {
		if err := unix.Mkdirat(d.fd(), name, 0o700); err != nil && err != unix.EEXIST {
			return nil, failed("mkdir", d.join(name), err)
		}
	}
	fd, err := unix.Openat(d.fd(), name, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
	switch {
	case err == unix.ENOENT:
		return nil, failed("open", d.join(name), fs.ErrNotExist)
	case err == unix.ELOOP || err == unix.ENOTDIR:
		return nil, failed("open", d.join(name), ErrNotOwn)
	case err != nil:
		return nil, failed("open", d.join(name), err)
	}
	if !own(fd, true) {
		unix.Close(fd)
		return nil, failed("open", d.join(name), ErrNotOwn)
	}
	return &Dir{f: os.NewFile(uintptr(fd), d.join(name))}, nil
}

// Open opens the file `name` in d, never through a link, with `flag` (the
// os package's), and refuses it unless it is a regular file of this user's
// own.
func (d *Dir) Open(name string, flag int, perm uint32) (*os.File, error) {
	if !plain(name) {
		return nil, failed("open", d.join(name), ErrNotOwnFile)
	}
	fd, err := unix.Openat(d.fd(), name, flag|unix.O_NOFOLLOW|unix.O_CLOEXEC, perm)
	switch {
	case err == unix.ENOENT:
		return nil, failed("open", d.join(name), fs.ErrNotExist)
	case err == unix.ELOOP:
		return nil, failed("open", d.join(name), ErrNotOwnFile)
	case err != nil:
		return nil, failed("open", d.join(name), err)
	}
	if !own(fd, false) {
		unix.Close(fd)
		return nil, failed("open", d.join(name), ErrNotOwnFile)
	}
	return os.NewFile(uintptr(fd), d.join(name)), nil
}

// CreateTemp makes a new file in d, 0600, named `prefix` and random hex,
// and answers it with its name.
func (d *Dir) CreateTemp(prefix string) (*os.File, string, error) {
	for {
		b := make([]byte, 8)
		_, _ = rand.Read(b)
		name := prefix + hex.EncodeToString(b)
		f, err := d.Open(name, os.O_RDWR|os.O_CREATE|os.O_EXCL, 0o600)
		if errors.Is(err, fs.ErrExist) {
			continue
		}
		return f, name, err
	}
}

// Info is what d holds under a name, looked at itself, never through a
// link.
type Info struct {
	Mode fs.FileMode
	Uid  uint32
	Size int64
}

// Lstat looks at `name` in d itself.
func (d *Dir) Lstat(name string) (Info, error) {
	if !plain(name) {
		return Info{}, failed("lstat", d.join(name), ErrNotOwnFile)
	}
	var st unix.Stat_t
	if err := unix.Fstatat(d.fd(), name, &st, unix.AT_SYMLINK_NOFOLLOW); err != nil {
		if err == unix.ENOENT {
			return Info{}, failed("lstat", d.join(name), fs.ErrNotExist)
		}
		return Info{}, failed("lstat", d.join(name), err)
	}
	mode := fs.FileMode(st.Mode & 0o777)
	switch st.Mode & unix.S_IFMT {
	case unix.S_IFDIR:
		mode |= fs.ModeDir
	case unix.S_IFLNK:
		mode |= fs.ModeSymlink
	case unix.S_IFREG:
	default:
		mode |= fs.ModeIrregular
	}
	return Info{Mode: mode, Uid: st.Uid, Size: st.Size}, nil
}

// Names are the names d holds.
func (d *Dir) Names() ([]string, error) {
	if _, err := d.f.Seek(0, io.SeekStart); err != nil {
		return nil, err
	}
	return d.f.Readdirnames(-1)
}

// Remove removes the file or link `name` from d, following nothing.
func (d *Dir) Remove(name string) error {
	if !plain(name) {
		return failed("remove", d.join(name), ErrNotOwnFile)
	}
	if err := unix.Unlinkat(d.fd(), name, 0); err != nil {
		if err == unix.ENOENT {
			return failed("remove", d.join(name), fs.ErrNotExist)
		}
		return failed("remove", d.join(name), err)
	}
	return nil
}

// Rename renames `from` to `to` in d.
func (d *Dir) Rename(from, to string) error {
	if !plain(from) || !plain(to) {
		return failed("rename", d.join(from), ErrNotOwnFile)
	}
	if err := unix.Renameat(d.fd(), from, d.fd(), to); err != nil {
		return failed("rename", d.join(from), err)
	}
	return nil
}

// RemoveAll removes `name` from d and, for a folder of this user's own,
// all it holds, following no link: a link named is refused; a link inside
// is removed itself. Nothing there is no error.
func (d *Dir) RemoveAll(name string) error {
	info, err := d.Lstat(name)
	switch {
	case Absent(err):
		return nil
	case err != nil:
		return err
	case info.Mode&fs.ModeSymlink != 0:
		return failed("remove", d.join(name), ErrNotOwnFile)
	case !info.Mode.IsDir():
		return d.Remove(name)
	}
	sub, err := d.Folder(name, false)
	if err != nil {
		return err
	}
	if err := sub.empty(); err != nil {
		sub.Close()
		return err
	}
	sub.Close()
	if err := unix.Unlinkat(d.fd(), name, unix.AT_REMOVEDIR); err != nil && err != unix.ENOENT {
		return failed("remove", d.join(name), err)
	}
	return nil
}

// empty removes all d holds, a folder's contents depth first, links
// removed themselves.
func (d *Dir) empty() error {
	names, err := d.Names()
	if err != nil {
		return err
	}
	for _, name := range names {
		info, err := d.Lstat(name)
		if Absent(err) {
			continue
		}
		if err != nil {
			return err
		}
		if info.Mode.IsDir() {
			if err := d.RemoveAll(name); err != nil {
				return err
			}
			continue
		}
		if err := d.Remove(name); err != nil && !Absent(err) {
			return err
		}
	}
	return nil
}

// Path is a file under a root, its relative way down: what a caller names
// once and reaches with the functions below.
type Path struct{ Root, Rel string }

// String is the path joined, for words and for a program to be told.
func (p Path) String() string { return filepath.Join(p.Root, p.Rel) }

// parent opens the folder that holds p, made when `create` is set, and
// answers p's last component.
func (p Path) parent(create bool) (*Dir, string, error) {
	all := steps(p.Rel)
	if len(all) == 0 {
		return nil, "", failed("open", p.String(), ErrNotOwnFile)
	}
	d, err := Walk(p.Root, strings.Join(all[:len(all)-1], "/"), create)
	return d, all[len(all)-1], err
}

// Present says whether p is there, a link at its end refused.
func Present(p Path) (bool, error) {
	d, name, err := p.parent(false)
	if Absent(err) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	defer d.Close()
	info, err := d.Lstat(name)
	switch {
	case Absent(err):
		return false, nil
	case err != nil:
		return false, err
	case info.Mode&fs.ModeSymlink != 0:
		return false, failed("lstat", p.String(), ErrNotOwnFile)
	}
	return true, nil
}

// RemoveAll removes p, as Dir.RemoveAll does; nothing there, or a missing
// folder on the way, is no error.
func RemoveAll(p Path) error {
	d, name, err := p.parent(false)
	if Absent(err) {
		return nil
	}
	if err != nil {
		return err
	}
	defer d.Close()
	return d.RemoveAll(name)
}

// Remove removes the file p.
func Remove(p Path) error {
	d, name, err := p.parent(false)
	if err != nil {
		return err
	}
	defer d.Close()
	return d.Remove(name)
}

// OpenFile opens the file p with `flag`, its folders made 0700 first when
// `create` is set.
func OpenFile(p Path, flag int, perm uint32, create bool) (*os.File, error) {
	d, name, err := p.parent(create)
	if err != nil {
		return nil, err
	}
	defer d.Close()
	return d.Open(name, flag, perm)
}

// ReadFile reads the file p.
func ReadFile(p Path) ([]byte, error) {
	f, err := OpenFile(p, os.O_RDONLY, 0, false)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	return io.ReadAll(f)
}

// WriteFile writes the file p, 0600, its folders made 0700 when missing.
func WriteFile(p Path, data []byte) error {
	f, err := OpenFile(p, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600, true)
	if err != nil {
		return err
	}
	_, err = f.Write(data)
	if closeErr := f.Close(); err == nil {
		err = closeErr
	}
	return err
}
