// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package residue

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"syscall"

	"golang.org/x/sys/unix"
)

// Bounds on one walk.
const (
	// MaxPaths is the most entries one Find reports.
	MaxPaths = 1024
	// maxDepth is the deepest directory level a walk descends to.
	maxDepth = 64
	// maxVisited is the most entries a walk examines.
	maxVisited = 200_000
)

// SysvipcDir is where the kernel lists System V IPC objects.
const SysvipcDir = "/proc/sysvipc"

// Found is what a uid has left behind.
type Found struct {
	// Paths are the outermost entries the uid owns on the writable mounts;
	// removing each removes everything below it.
	Paths []string
	// Truncated is set when a walk stopped at one of its bounds, so entries
	// of the uid may remain beyond Paths.
	Truncated bool
	// IPC are the System V IPC objects the uid owns or created.
	IPC []IPC
	// Queues are the names of the POSIX message queues the uid owns.
	Queues []string
}

// Empty reports whether nothing of the uid remains.
func (f Found) Empty() bool {
	return len(f.Paths) == 0 && !f.Truncated && len(f.IPC) == 0 && len(f.Queues) == 0
}

// Find reports what uid has left under roots and in the System V IPC tables
// listed under sysvipcDir. It reads with the calling process's permissions
// and never follows a symbolic link or leaves the mount it walks; a
// directory it cannot open is not searched, and a pooled uid cannot search
// it either.
func Find(roots Roots, sysvipcDir string, uid int) (Found, error) {
	var found Found
	w := &walker{uid: uid, found: &found}
	for _, dir := range roots.Dirs {
		if err := w.root(dir); err != nil {
			return Found{}, err
		}
	}
	ipc, err := FindIPC(sysvipcDir, uid)
	if err != nil {
		return Found{}, err
	}
	found.IPC = ipc
	if roots.Queues != "" {
		queues, err := FindQueues(roots.Queues, uid)
		if err != nil {
			return Found{}, err
		}
		found.Queues = queues
	}
	return found, nil
}

// FindIPC lists the System V IPC objects uid owns or created. A kernel
// without System V IPC has no tables and no objects.
func FindIPC(sysvipcDir string, uid int) ([]IPC, error) {
	var out []IPC
	for _, kind := range IPCKinds {
		data, err := os.ReadFile(filepath.Join(sysvipcDir, kind))
		if errors.Is(err, fs.ErrNotExist) {
			continue
		}
		if err != nil {
			return nil, err
		}
		objs, err := ParseSysvipc(kind, data, uid)
		if err != nil {
			return nil, err
		}
		out = append(out, objs...)
	}
	return out, nil
}

// FindQueues lists the message queues in the mqueue mount dir owned by uid.
func FindQueues(dir string, uid int) ([]string, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	var out []string
	for _, e := range entries {
		info, err := e.Info()
		if errors.Is(err, fs.ErrNotExist) {
			continue
		}
		if err != nil {
			return nil, err
		}
		if st, ok := info.Sys().(*syscall.Stat_t); ok && int(st.Uid) == uid {
			out = append(out, e.Name())
		}
	}
	return out, nil
}

type walker struct {
	uid     int
	found   *Found
	visited int
}

func (w *walker) root(dir string) error {
	fd, err := unix.Open(dir, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
	if err != nil {
		if unreachable(err) {
			return nil
		}
		return fmt.Errorf("open %s: %w", dir, err)
	}
	defer unix.Close(fd)
	var st unix.Stat_t
	if err := unix.Fstat(fd, &st); err != nil {
		return fmt.Errorf("stat %s: %w", dir, err)
	}
	return w.dir(fd, dir, uint64(st.Dev), 0)
}

// dir records the entries of the directory open as fd that the uid owns and
// descends into the others it can open, on the same device.
func (w *walker) dir(fd int, path string, dev uint64, depth int) error {
	names, err := readNames(fd)
	if err != nil {
		if unreachable(err) {
			return nil
		}
		return fmt.Errorf("list %s: %w", path, err)
	}
	for _, name := range names {
		if len(w.found.Paths) >= MaxPaths || w.visited >= maxVisited {
			w.found.Truncated = true
			return nil
		}
		w.visited++
		child := filepath.Join(path, name)
		var st unix.Stat_t
		if err := unix.Fstatat(fd, name, &st, unix.AT_SYMLINK_NOFOLLOW); err != nil {
			if unreachable(err) {
				continue
			}
			return fmt.Errorf("stat %s: %w", child, err)
		}
		if uint64(st.Dev) != dev {
			continue
		}
		if int(st.Uid) == w.uid {
			w.found.Paths = append(w.found.Paths, child)
			continue
		}
		if uint32(st.Mode)&unix.S_IFMT != unix.S_IFDIR {
			continue
		}
		if depth+1 >= maxDepth {
			w.found.Truncated = true
			continue
		}
		cfd, err := unix.Openat(fd, name, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
		if err != nil {
			if unreachable(err) {
				continue
			}
			return fmt.Errorf("open %s: %w", child, err)
		}
		err = w.dir(cfd, child, dev, depth+1)
		unix.Close(cfd)
		if err != nil {
			return err
		}
	}
	return nil
}

// readNames lists the directory open as fd, once: the listing reads through
// a duplicate that shares fd's offset, and fd stays open for *at calls.
func readNames(fd int) ([]string, error) {
	dup, err := unix.Dup(fd)
	if err != nil {
		return nil, err
	}
	dir := os.NewFile(uintptr(dup), "dir")
	defer dir.Close()
	return dir.Readdirnames(-1)
}

// unreachable reports an error meaning the entry is gone or closed to the
// caller: removed while the walk ran, not searchable, replaced by a
// non-directory or a symbolic link.
func unreachable(err error) bool {
	return errors.Is(err, unix.ENOENT) || errors.Is(err, unix.EACCES) || errors.Is(err, unix.EPERM) ||
		errors.Is(err, unix.ENOTDIR) || errors.Is(err, unix.ELOOP)
}
