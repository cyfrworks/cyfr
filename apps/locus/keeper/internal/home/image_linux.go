// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package home

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

// Mke2fs makes an image's filesystem; MakeImageWait bounds it. Variables
// so a test points them elsewhere.
var (
	Mke2fs        = "/usr/sbin/mke2fs"
	MakeImageWait = 2 * time.Minute
)

// EnsureImage makes the image of athanor's disk unless it stands: a
// temporary beside it, of the disk's uid and its own group (as a kept
// spawn runs, KeptAccount), ImageMode, ImageBytes long, made an ext4
// filesystem by mke2fs within MakeImageWait, synced and then renamed into
// place. A failure leaves no temporary, and a temporary
// a dead keeper left is removed at the next LoadDisks. The disk's lock is
// held, so no two makings of one image run at once. A number outside 0 to
// 2^31-1 is no uid, and is refused before anything is made.
func (k Kept) EnsureImage(athanor string, uid int) error {
	if uid < 0 || uid >= 1<<31 {
		return fmt.Errorf("the disk's uid %d is not a uid", uid)
	}
	path := k.ImagePath(athanor)
	if st, err := os.Lstat(path); err == nil {
		if !st.Mode().IsRegular() {
			return fmt.Errorf("%s is not a regular file", path)
		}
		return nil
	} else if !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	var tmp string
	err := AsFileIDs(uid, uid, func() error {
		f, err := os.CreateTemp(k.Root, "."+Person(athanor)+ImageSuffix+".*")
		if err != nil {
			return err
		}
		tmp = f.Name()
		if err := f.Chmod(ImageMode); err != nil {
			_ = f.Close()
			return err
		}
		if err := f.Truncate(ImageBytes); err != nil {
			_ = f.Close()
			return err
		}
		return f.Close()
	})
	// The keeper holds no capability over files: the image, its uid's
	// alone, is made and synced as that uid.
	if err == nil {
		err = makeFilesystem(tmp, uid)
	}
	if err == nil {
		err = AsFileIDs(uid, uid, func() error { return syncFile(tmp) })
	}
	if err == nil {
		err = os.Rename(tmp, path)
	}
	if err == nil {
		err = syncDir(k.Root)
	}
	if err != nil {
		if tmp != "" {
			_ = os.Remove(tmp)
		}
		return fmt.Errorf("making the disk image %s: %w", path, err)
	}
	return nil
}

// ErrNotImage is something at a disk image's path that is not its image:
// no regular file, or one another uid owns, or open to any other uid.
var ErrNotImage = errors.New("not the disk's image: a regular file of its uid's alone, mode 0600")

// CheckImage reports whether path is a disk's image as its VM is given it
// at each start: a regular file, read without following a link, of uid and
// its group, mode ImageMode. An absent one is fs.ErrNotExist; anything else
// there is ErrNotImage.
func CheckImage(path string, uid int) error {
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	st, ok := info.Sys().(*syscall.Stat_t)
	if !ok || info.Mode() != ImageMode || int(st.Uid) != uid || int(st.Gid) != uid {
		return fmt.Errorf("%s: %w", path, ErrNotImage)
	}
	return nil
}

// makeFilesystem runs mke2fs as uid on the file at path, uid's, in a
// process group of its own killed whole past MakeImageWait: ext4, no blocks
// reserved, its inode tables and journal left to the guest's first mount to
// initialize, and the file not discarded, so it stays sparse.
func makeFilesystem(path string, uid int) error {
	ctx, cancel := context.WithTimeout(context.Background(), MakeImageWait)
	defer cancel()
	cmd := exec.Command(Mke2fs, "-q", "-F", "-t", "ext4", "-m", "0",
		"-E", "lazy_itable_init=1,lazy_journal_init=1,nodiscard", path)
	cmd.Env = []string{}
	var out bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &out
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true, Pdeathsig: syscall.SIGKILL}
	if uid != os.Getuid() {
		cmd.SysProcAttr.Credential = &syscall.Credential{Uid: uint32(uid), Gid: uint32(uid), Groups: []uint32{}}
	}
	if err := cmd.Start(); err != nil {
		return err
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case err := <-done:
		if err != nil {
			return fmt.Errorf("mke2fs: %w: %s", err, strings.TrimSpace(out.String()))
		}
		return nil
	case <-ctx.Done():
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		<-done
		return fmt.Errorf("mke2fs did not finish within %s", MakeImageWait)
	}
}

func syncFile(path string) error {
	f, err := os.OpenFile(path, os.O_RDWR, 0)
	if err != nil {
		return err
	}
	err = f.Sync()
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	return err
}

func syncDir(dir string) error {
	f, err := os.Open(dir)
	if err != nil {
		return err
	}
	err = unix.Fsync(int(f.Fd()))
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	return err
}
