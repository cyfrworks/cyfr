// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package vm

import (
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

// The image's programs' device: one squashfs for every machine, made by the
// keeper from its own container's read-only root, which is the image, the
// first time it needs one under that image.
const (
	// ProgramsDir is the backends service's `guest` volume, which outlives
	// the container, so a release's device is made once.
	ProgramsDir = "/var/lib/locus/guest"
	// DigestFile holds the image's identity, a digest of its root's
	// contents written at its build (Dockerfile.locus), which names its
	// device: a new release makes a new one.
	DigestFile = "/etc/cyfr/image-digest"
	// Mksquashfs is the maker, from the image's squashfs-tools.
	Mksquashfs = "/usr/bin/mksquashfs"
	// MakeWait bounds a start's wait for a device another start is making.
	// Warm, the making took 1.1 to 3.2 s (plan V1); cold, it is one read
	// of the image's 2.1 GB root.
	MakeWait = 3 * time.Minute
)

// ErrMaking refuses a start that waited MakeWait for the device.
var ErrMaking = errors.New("the image's programs are still being made into the machines' device")

var digestPattern = regexp.MustCompile(`^[0-9a-f]{64}$`)

// Maker makes the image's programs' device. Programs is the image's own;
// the fields are its paths and bound.
type Maker struct {
	Dir    string
	Digest string
	Tool   string
	Root   string
	Wait   time.Duration
	// Log takes the maker's own output.
	Log io.Writer
}

// Programs is the keeper's maker: the container's root into ProgramsDir.
func Programs(log io.Writer) Maker {
	return Maker{Dir: ProgramsDir, Digest: DigestFile, Tool: Mksquashfs, Root: "/", Wait: MakeWait, Log: log}
}

// MakeArgs are the maker's flags. -one-file-system is the wall's part of
// them: the walk stays on the root's own filesystem, so no other mount, a
// folder or a single bound file, enters the device, the kept homes' volume
// and Docker's /etc/hosts, resolv.conf and hostname among them (the image
// case holds a device to it). -mem bounds the maker's caches inside the
// container's memory.
func MakeArgs(root, out string) []string {
	return []string{root, out, "-one-file-system", "-comp", "lz4", "-noappend", "-no-progress", "-quiet", "-mem", "256M"}
}

// Device is the device of this image, made if there is none, and whether
// this call made it. One maker at a time: a call that finds another making
// waits up to Wait and then refuses with ErrMaking.
func (mk Maker) Device() (path string, made bool, err error) {
	raw, err := os.ReadFile(mk.Digest)
	if err != nil {
		return "", false, fmt.Errorf("the image's identity: %w", err)
	}
	digest := strings.TrimSpace(string(raw))
	if !digestPattern.MatchString(digest) {
		return "", false, fmt.Errorf("the image's identity %q is not a sha256", digest)
	}
	lock, err := os.OpenFile(filepath.Join(mk.Dir, ".lock"), os.O_CREATE|os.O_RDWR|syscall.O_CLOEXEC, 0o600)
	if err != nil {
		return "", false, fmt.Errorf("the machines' device's lock: %w", err)
	}
	defer lock.Close()
	if err := lockWithin(lock, mk.Wait); err != nil {
		return "", false, err
	}
	path = filepath.Join(mk.Dir, digest+".sqfs")
	if _, err := os.Stat(path); err == nil {
		return path, false, nil
	}
	if err := mk.make(path); err != nil {
		return "", false, err
	}
	// The old release's device goes once this one is whole.
	entries, _ := os.ReadDir(mk.Dir)
	for _, e := range entries {
		if name := e.Name(); strings.HasSuffix(name, ".sqfs") && name != digest+".sqfs" {
			_ = os.Remove(filepath.Join(mk.Dir, name))
		}
	}
	return path, true, nil
}

// make writes the device to a temporary name, syncs it and renames it
// whole, after removing any temporary file a maker that died left.
func (mk Maker) make(path string) error {
	entries, _ := os.ReadDir(mk.Dir)
	for _, e := range entries {
		if strings.HasSuffix(e.Name(), ".tmp") {
			_ = os.Remove(filepath.Join(mk.Dir, e.Name()))
		}
	}
	tmp := path + ".tmp"
	cmd := exec.Command(mk.Tool, MakeArgs(mk.Root, tmp)...)
	cmd.Env = []string{"PATH=/usr/bin:/bin"}
	cmd.Stdout, cmd.Stderr = mk.Log, mk.Log
	cmd.SysProcAttr = &syscall.SysProcAttr{Pdeathsig: syscall.SIGKILL}
	if err := cmd.Run(); err != nil {
		_ = os.Remove(tmp)
		return fmt.Errorf("making the machines' device: %w", err)
	}
	f, err := os.Open(tmp)
	if err == nil {
		err = f.Sync()
		_ = f.Close()
	}
	if err == nil {
		// The VMM reads it as the keeper's group (Config.UID).
		err = os.Chmod(tmp, 0o640)
	}
	if err == nil {
		err = os.Rename(tmp, path)
	}
	if err != nil {
		_ = os.Remove(tmp)
		return fmt.Errorf("making the machines' device: %w", err)
	}
	if dir, err := os.Open(mk.Dir); err == nil {
		_ = dir.Sync()
		_ = dir.Close()
	}
	return nil
}

// lockWait is the pause between two tries for a lock another maker holds.
const lockWait = 100 * time.Millisecond

// lockWithin takes f's exclusive lock, waiting up to d.
func lockWithin(f *os.File, d time.Duration) error {
	deadline := time.Now().Add(d)
	for {
		err := unix.Flock(int(f.Fd()), unix.LOCK_EX|unix.LOCK_NB)
		if err == nil {
			return nil
		}
		if !errors.Is(err, unix.EWOULDBLOCK) && !errors.Is(err, unix.EINTR) {
			return fmt.Errorf("the machines' device's lock: %w", err)
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("%w: another start has been making it for %s", ErrMaking, d)
		}
		time.Sleep(lockWait)
	}
}
