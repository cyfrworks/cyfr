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
// absolute or climbs refused, as GNU tar refuses it), and dd of=FILE of
// stdin in place; the clear's list is kept, appended, in clear.list. The
// scenario's write.kill, "N K", ends the N-th write
// (counted in write.count) as a killed container does, with status 137,
// once it has written K entries (a list's names, an archive's entries); a
// write.stall makes every write take nothing until it is ended.
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
		var n, k int
		fmt.Sscan(string(raw), &n, &k)
		if n == count {
			budget = k
		}
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
		err = v.extract(tar.NewReader(c.Stdin), args[4], spend)
	case program == "dd" && len(args) == 3 && strings.HasPrefix(args[0], "of=") && args[1] == "bs=1M" && args[2] == "status=none":
		if err = spend(); err == nil {
			err = v.writeFile(strings.TrimPrefix(args[0], "of="), c.Stdin)
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

// extract writes the archive's entries under the container directory dir.
func (v containerView) extract(tr *tar.Reader, dir string, spend func() error) error {
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
		if err := spend(); err != nil {
			return err
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
			_, err = io.Copy(f, tr)
			if err = errors.Join(err, f.Chmod(fs.FileMode(h.Mode)), f.Close()); err != nil {
				return err
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
