// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"archive/tar"
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"syscall"

	"github.com/cyfr/codex/internal/access"
)

// standInStackWrite answers a write through the stack as its container
// would, through the scenario's binds, each written only where it is
// mounted writable: xargs -0 -r rm -rf -- on the list on stdin, rm -f --
// on its operands, tar -x -f - -C DIR of the archive on stdin (an
// existing directory kept, any other entry replaced, a name that is
// absolute or climbs refused, as GNU tar refuses it), dd of=FILE of stdin
// in place, sync -- on its operands, and mv -f -T -- A B (a rename, never
// over a mount's target); the clear's list is kept, appended, in
// clear.list. The scenario's write.kill, "N K", ends the N-th write
// (counted in write.count) as a killed container does, with status 137,
// once it has written K entries (a list's names, an archive's entries, a
// command's operands), or with K "x" before it writes anything; "@TEXT K" ends the first write whose arguments
// hold TEXT so. A file the kill reaches is left half written, as a
// killed tar or dd leaves it. A write.stall makes every write take
// nothing until it is ended.
func standInStackWrite(ctx context.Context, c access.Call, v containerView, program string, args []string) (access.Result, error) {
	d := os.Getenv("FAKE_DOCKER_DIR")
	count := 1
	if raw, err := os.ReadFile(filepath.Join(d, "write.count")); err == nil {
		count, _ = strconv.Atoi(strings.TrimSpace(string(raw)))
		count++
	}
	os.WriteFile(filepath.Join(d, "write.count"), []byte(strconv.Itoa(count)), 0o644)
	budget := -1
	if raw, err := os.ReadFile(filepath.Join(d, "write.kill")); err == nil {
		line := strings.TrimSpace(string(raw))
		cut := strings.LastIndex(line, " ")
		spec, k := line[:max(cut, 0)], line[cut+1:]
		at, err := strconv.Atoi(k)
		if err != nil {
			// "x": before it writes anything.
			at = -2
		}
		if text, ok := strings.CutPrefix(spec, "@"); ok && strings.Contains(strings.Join(args, " "), text) {
			budget = at
			os.Remove(filepath.Join(d, "write.kill"))
		} else if n, err := strconv.Atoi(spec); err == nil && n == count {
			budget = at
		}
	}
	if budget == -2 {
		return access.Result{ExitCode: 137}, nil
	}
	if _, err := os.Stat(filepath.Join(d, "write.stall")); err == nil {
		<-ctx.Done()
		return access.Result{ExitCode: 137}, nil
	}
	if standInAsRoot != nil {
		defer standInAsRoot()()
	}
	killed := errors.New("killed")
	spend := func() error {
		if budget == 0 {
			return killed
		}
		budget--
		return nil
	}
	// half is how much of a file of n bytes is written before the kill
	// reaches it: half of it when this entry is the one it ends at.
	half := func(n int64) int64 {
		if budget == 0 {
			return n / 2
		}
		return n
	}
	var err error
	switch {
	case program == "xargs" && slices.Equal(args, []string{"-0", "-r", "rm", "-rf", "--"}):
		var list []byte
		if list, err = io.ReadAll(c.Stdin); err == nil {
			f, _ := os.OpenFile(filepath.Join(d, "clear.list"), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
			f.Write(list)
			f.Close()
			for _, name := range bytes.Split(list, []byte{0}) {
				if len(name) == 0 {
					continue
				}
				if err = spend(); err == nil {
					err = v.remove(string(name), true)
				}
				if err != nil {
					break
				}
			}
		}
	case program == "rm" && len(args) > 2 && args[0] == "-f" && args[1] == "--":
		for _, p := range args[2:] {
			if err = spend(); err == nil {
				err = v.remove(p, false)
			}
			if err != nil {
				break
			}
		}
	case program == "tar" && len(args) == 7 && slices.Equal(args[:4], []string{"-x", "-f", "-", "-C"}) && slices.Equal(args[5:], []string{"--no-same-owner", "--no-overwrite-dir"}):
		err = v.extract(tar.NewReader(c.Stdin), args[4], spend, half, killed)
	case program == "dd" && slices.Equal(args[1:], []string{"bs=1M", "conv=fsync", "status=none"}) && strings.HasPrefix(args[0], "of="):
		data, _ := io.ReadAll(c.Stdin)
		n := half(int64(len(data)))
		if err = v.writeFile(strings.TrimPrefix(args[0], "of="), bytes.NewReader(data[:n])); err == nil && n < int64(len(data)) {
			err = killed
		}
	case program == "sync" && len(args) > 1 && args[0] == "--":
		for _, p := range args[1:] {
			if err = spend(); err == nil {
				var h string
				if h, err = v.host(p); err == nil {
					_, err = os.Stat(h)
				}
			}
			if err != nil {
				break
			}
		}
	case program == "mv" && len(args) == 5 && slices.Equal(args[:3], []string{"-f", "-T", "--"}):
		if err = spend(); err == nil {
			var from, to string
			if from, err = v.writable(args[3], true); err == nil {
				if to, err = v.writable(args[4], true); err == nil {
					err = os.Rename(from, to)
				}
			}
		}
	default:
		err = fmt.Errorf("the stand-in writes with no %s %s", program, strings.Join(args, " "))
	}
	if errors.Is(err, killed) {
		return access.Result{ExitCode: 137}, nil
	}
	if err != nil {
		if c.Stderr != nil {
			fmt.Fprintln(c.Stderr, err)
		}
		return access.Result{ExitCode: 2, Stderr: []byte(err.Error())}, nil
	}
	return access.Result{}, nil
}

// writable answers the host path of the container path p, or why the
// container may not write there: on no bind, on one mounted read only, or
// at a mount's target, which cannot be removed or replaced (busy).
func (v containerView) writable(p string, replace bool) (string, error) {
	m, _, ok := holdingMount(v.binds, p)
	if !ok {
		return "", fmt.Errorf("%s: no bind holds it", p)
	}
	if v.readonly[path.Clean(m.Target)] {
		return "", &fs.PathError{Op: "write", Path: p, Err: syscall.EROFS}
	}
	if replace && slices.ContainsFunc(v.binds, func(b composeMount) bool { return path.Clean(b.Target) == p }) {
		return "", &fs.PathError{Op: "remove", Path: p, Err: syscall.EBUSY}
	}
	h, _ := mountedHost(v.binds, p)
	return h, nil
}

// remove removes the container path p, never following a link at it, its
// tree with all.
func (v containerView) remove(p string, all bool) error {
	h, err := v.writable(p, true)
	if err != nil {
		return err
	}
	if all {
		return os.RemoveAll(h)
	}
	if err := os.Remove(h); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	return nil
}

// extract writes the archive's entries under the container directory dir,
// a file the kill reaches half written (half).
func (v containerView) extract(tr *tar.Reader, dir string, spend func() error, half func(int64) int64, killed error) error {
	for {
		h, err := tr.Next()
		if errors.Is(err, io.EOF) {
			return nil
		}
		if err != nil {
			return err
		}
		name := strings.TrimSuffix(h.Name, "/")
		if path.IsAbs(name) || !fs.ValidPath(name) {
			return fmt.Errorf("tar: %s: member name refused", h.Name)
		}
		cut := half(h.Size) < h.Size
		if !cut {
			if err := spend(); err != nil {
				return err
			}
		}
		p := path.Join(dir, name)
		host, err := v.writable(p, h.Typeflag != tar.TypeDir)
		if err != nil {
			return err
		}
		info, statErr := os.Lstat(host)
		switch h.Typeflag {
		case tar.TypeDir:
			if statErr == nil && info.IsDir() {
				continue
			}
			if err := os.Mkdir(host, 0o700); err != nil {
				return err
			}
			if err := os.Chmod(host, fs.FileMode(h.Mode)); err != nil {
				return err
			}
		case tar.TypeReg, tar.TypeSymlink:
			if statErr == nil {
				if info.IsDir() {
					return fmt.Errorf("tar: %s: cannot replace a directory", h.Name)
				}
				if err := os.Remove(host); err != nil {
					return err
				}
			}
			if h.Typeflag == tar.TypeSymlink {
				if err := os.Symlink(h.Linkname, host); err != nil {
					return err
				}
				continue
			}
			f, err := os.OpenFile(host, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
			if err != nil {
				return err
			}
			_, err = io.CopyN(f, tr, half(h.Size))
			if err = errors.Join(err, f.Chmod(fs.FileMode(h.Mode)), f.Close()); err != nil {
				return err
			}
			if cut {
				return killed
			}
		default:
			return fmt.Errorf("tar: %s: the stand-in extracts no type %c", h.Name, h.Typeflag)
		}
	}
}

// writeFile writes r over the container path p in place, as dd of= does.
func (v containerView) writeFile(p string, r io.Reader) error {
	host, err := v.writable(p, false)
	if err != nil {
		return err
	}
	f, err := os.OpenFile(host, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o644)
	if err != nil {
		return err
	}
	_, err = io.Copy(f, r)
	return errors.Join(err, f.Close())
}
