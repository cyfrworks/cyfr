// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package disk reports whether this machine's root filesystem and CYFR's data
// directory sit on an encrypted block device. It only reads mountinfo, sysfs
// and stat results: it writes nothing, enrolls nothing, changes no boot
// configuration and says nothing about Secure Boot.
//
// The answer is about the block layer. Encrypted means every route from the
// filesystem's block device down to a disk passes through an encrypting
// device-mapper mapping; Unencrypted means block-device evidence shows a
// route that reaches a disk without one; anything else is Unknown, and
// Unknown is never reported as Encrypted. Filesystem-level encryption is not
// seen: fscrypt on a plain partition reads Unencrypted, and eCryptfs and ZFS
// native encryption read Unknown because their mount source is no block
// device.
package disk

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// State is what is known about one path's encryption at rest.
type State string

const (
	Encrypted   State = "encrypted"
	Unencrypted State = "unencrypted"
	Unknown     State = "unknown"
)

// Report holds the state of the root filesystem and of the data directory.
// Each comes from its own path's mount, so a data directory on another disk
// than root's is reported by that disk.
type Report struct {
	Root, Data State
}

// Capabilities names the report as exactly two capabilities, root's first:
// "root_<state>" and "data_<state>".
func (r Report) Capabilities() []string {
	return []string{"root_" + string(r.Root), "data_" + string(r.Data)}
}

// System is the view of a machine a detection reads. Zero fields read the
// running Linux system.
type System struct {
	// MountInfo is the path of a mountinfo table; the default is
	// /proc/self/mountinfo.
	MountInfo string
	// Sys is the sysfs root; the default is /sys. Its dev/block/<major>:<minor>
	// and slaves entries are relative symlinks into its devices tree, as in
	// the kernel's sysfs.
	Sys string
	// Stat reports the device number a path names: a block device node's own
	// number, or else the number of the filesystem holding the path.
	Stat func(path string) (major, minor uint32, err error)
}

// maxDepth bounds the block devices one walk passes through, so a cycle or an
// absurd stack ends as Unknown.
const maxDepth = 16

// encryptingTypes are the libcryptsetup device types whose mappings encrypt
// the data. libcryptsetup names a mapping's dm uuid "CRYPT-<type>-...";
// VERITY, INTEGRITY and SUBDEV mappings carry the same prefix but only check
// or store integrity data, so they are classified by the devices beneath.
var encryptingTypes = map[string]bool{
	"LUKS1": true, "LUKS2": true, "PLAIN": true, "LOOPAES": true,
	"TCRYPT": true, "BITLK": true, "FVAULT2": true,
}

// Detect reports the states of the filesystems holding rootDir and dataDir.
// A path is matched to a mount point as given, so a caller resolves symlinks
// first when the path's mount point prefix should count.
func (s System) Detect(rootDir, dataDir string) Report {
	if s.MountInfo == "" {
		s.MountInfo = "/proc/self/mountinfo"
	}
	if s.Sys == "" {
		s.Sys = "/sys"
	}
	if s.Stat == nil {
		s.Stat = statDevice
	}
	mounts, err := readMounts(s.MountInfo)
	if err != nil {
		return Report{Root: Unknown, Data: Unknown}
	}
	d := detector{System: s, mounts: mounts}
	return Report{Root: d.path(rootDir, 0), Data: d.path(dataDir, 0)}
}

type devNum struct{ major, minor uint32 }

type mount struct {
	dev    devNum
	point  string
	source string
}

type detector struct {
	System
	mounts []mount
}

// path classifies the filesystem holding p; depth counts the block devices
// already passed on this walk.
func (d detector) path(p string, depth int) State {
	abs, err := filepath.Abs(p)
	if err != nil {
		return Unknown
	}
	major, minor, err := d.Stat(abs)
	if err != nil {
		return Unknown
	}
	m, ok := d.mountOf(abs, devNum{major, minor})
	if !ok {
		return Unknown
	}
	dev := m.dev
	if dev.major == 0 {
		// A filesystem with no block device number of its own (btrfs,
		// overlay, tmpfs, ZFS, NFS) is classified by its mount source when
		// that names a block device node.
		if !strings.HasPrefix(m.source, "/dev/") {
			return Unknown
		}
		if dev.major, dev.minor, err = d.Stat(m.source); err != nil || dev.major == 0 {
			return Unknown
		}
	}
	dir, err := filepath.EvalSymlinks(filepath.Join(d.Sys, "dev", "block", fmt.Sprintf("%d:%d", dev.major, dev.minor)))
	if err != nil {
		return Unknown
	}
	return d.node(dir, depth+1)
}

// mountOf finds the mount holding p: of the mounts of p's device, the one
// with the longest mount point containing p (any of them when none contains
// it, since they share the device). When mountinfo lists no mount of p's
// device, as for a btrfs subvolume that is not itself mounted, it is the
// mount with the longest mount point containing p.
func (d detector) mountOf(p string, dev devNum) (mount, bool) {
	var same []mount
	for _, m := range d.mounts {
		if m.dev == dev {
			same = append(same, m)
		}
	}
	if len(same) == 0 {
		return longestContaining(d.mounts, p)
	}
	if m, ok := longestContaining(same, p); ok {
		return m, true
	}
	return same[0], true
}

// longestContaining returns the mount with the longest mount point containing
// p; of equal mount points the later line wins, since a later mount covers an
// earlier one.
func longestContaining(mounts []mount, p string) (mount, bool) {
	var best mount
	found := false
	for _, m := range mounts {
		contains := m.point == "/" || p == m.point || strings.HasPrefix(p, m.point+"/")
		if contains && (!found || len(m.point) >= len(best.point)) {
			best, found = m, true
		}
	}
	return best, found
}

// node classifies the block device whose sysfs directory is dir.
func (d detector) node(dir string, depth int) State {
	if depth > maxDepth {
		return Unknown
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return Unknown
	}
	has := map[string]bool{}
	for _, e := range entries {
		has[e.Name()] = true
	}
	switch {
	case has["dm"]:
		uuid, err := os.ReadFile(filepath.Join(dir, "dm", "uuid"))
		if err != nil {
			return Unknown
		}
		if encrypting(strings.TrimSpace(string(uuid))) {
			return Encrypted
		}
		return d.lower(dir, depth)
	case has["partition"]:
		return d.node(filepath.Dir(dir), depth+1)
	case has["md"]:
		return d.lower(dir, depth)
	case strings.HasPrefix(filepath.Base(dir), "loop"):
		backing, err := os.ReadFile(filepath.Join(dir, "loop", "backing_file"))
		if err != nil {
			return Unknown
		}
		return d.path(strings.TrimSuffix(string(backing), "\n"), depth)
	case has["slaves"]:
		slaves, err := os.ReadDir(filepath.Join(dir, "slaves"))
		if err != nil {
			return Unknown
		}
		if len(slaves) > 0 {
			return d.lower(dir, depth)
		}
	}
	// A whole disk stacked on nothing is the plain bottom of the stack.
	return Unencrypted
}

// lower combines the states of the devices a stacked device sits on. A plain
// lower device holds data unencrypted, so one decides; otherwise an unknown
// lower device leaves the whole unknown, and only encrypted lower devices
// throughout make it encrypted.
func (d detector) lower(dir string, depth int) State {
	slaves, err := os.ReadDir(filepath.Join(dir, "slaves"))
	if err != nil || len(slaves) == 0 {
		return Unknown
	}
	state := Encrypted
	for _, e := range slaves {
		branch := Unknown
		if next, err := filepath.EvalSymlinks(filepath.Join(dir, "slaves", e.Name())); err == nil {
			branch = d.node(next, depth+1)
		}
		switch branch {
		case Unencrypted:
			return Unencrypted
		case Unknown:
			state = Unknown
		}
	}
	return state
}

func encrypting(uuid string) bool {
	rest, ok := strings.CutPrefix(uuid, "CRYPT-")
	if !ok {
		return false
	}
	kind, _, _ := strings.Cut(rest, "-")
	return encryptingTypes[kind]
}

var errMountInfo = errors.New("malformed mountinfo line")

// readMounts parses a mountinfo table. A line it cannot parse fails the whole
// table: skipping it could hand that mount's paths to a parent mount.
func readMounts(path string) ([]mount, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var mounts []mount
	for line := range strings.Lines(string(b)) {
		f := strings.Fields(line)
		if len(f) == 0 {
			continue
		}
		// id parent major:minor root point options [optional...] - type source super
		sep := -1
		for i := 6; i < len(f); i++ {
			if f[i] == "-" {
				sep = i
				break
			}
		}
		if sep < 0 || len(f) < sep+3 {
			return nil, fmt.Errorf("%w: %q", errMountInfo, line)
		}
		majorText, minorText, ok := strings.Cut(f[2], ":")
		major, err1 := strconv.ParseUint(majorText, 10, 32)
		minor, err2 := strconv.ParseUint(minorText, 10, 32)
		if !ok || err1 != nil || err2 != nil {
			return nil, fmt.Errorf("%w: %q", errMountInfo, line)
		}
		mounts = append(mounts, mount{
			dev:    devNum{uint32(major), uint32(minor)},
			point:  unescape(f[4]),
			source: unescape(f[sep+2]),
		})
	}
	return mounts, nil
}

// unescape decodes mountinfo's octal escapes (\040 for a space, \011, \012,
// \134).
func unescape(s string) string {
	if !strings.Contains(s, `\`) {
		return s
	}
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		if s[i] == '\\' && i+4 <= len(s) {
			if c, err := strconv.ParseUint(s[i+1:i+4], 8, 8); err == nil {
				b.WriteByte(byte(c))
				i += 3
				continue
			}
		}
		b.WriteByte(s[i])
	}
	return b.String()
}
