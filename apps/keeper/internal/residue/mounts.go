// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package residue finds and removes what a pooled uid leaves behind once its
// processes are gone: the entries it owns on the writable mounts, the System
// V IPC objects it owns or created, and its POSIX message queues. A uid is
// lent to the next spawn only when none of these remain, so nothing one
// holder writes outside its processes reaches the next holder of the uid.
//
// Where a pooled uid can write is read from the mount table. CheckMounts
// refuses a table under which the pool could write anywhere shared except
// the home root, and Find walks every writable mount.
package residue

import (
	"bufio"
	"bytes"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"
)

// Mount is one mount of /proc/<pid>/mountinfo.
type Mount struct {
	// Point is the mount point, unescaped.
	Point string
	// FSType is the filesystem type.
	FSType string
	// Writable is false when the mount or its superblock is read-only.
	Writable bool
}

// pseudoFS are filesystem types in which an unprivileged process creates no
// entry that outlives it; they are not walked.
var pseudoFS = map[string]bool{
	"autofs": true, "binfmt_misc": true, "bpf": true, "cgroup": true, "cgroup2": true,
	"configfs": true, "debugfs": true, "devpts": true, "efivarfs": true, "fusectl": true,
	"nsfs": true, "proc": true, "pstore": true, "rpc_pipefs": true, "securityfs": true,
	"selinuxfs": true, "sysfs": true, "tracefs": true,
}

// queueFS is the filesystem POSIX message queues are listed from.
const queueFS = "mqueue"

// ParseMountinfo parses a mountinfo file (proc(5)): for each line the mount
// point (field 5), the per-mount options (field 6), and after the `-`
// separator the filesystem type and the superblock options.
func ParseMountinfo(data []byte) ([]Mount, error) {
	var mounts []Mount
	sc := bufio.NewScanner(bytes.NewReader(data))
	sc.Buffer(make([]byte, 0, 64<<10), 1<<20)
	for sc.Scan() {
		fields := strings.Fields(sc.Text())
		if len(fields) == 0 {
			continue
		}
		sep := -1
		for i := 6; i < len(fields); i++ {
			if fields[i] == "-" {
				sep = i
				break
			}
		}
		if len(fields) < 6 || sep < 0 || len(fields) < sep+4 {
			return nil, fmt.Errorf("mountinfo: malformed line %q", sc.Text())
		}
		point, err := unescape(fields[4])
		if err != nil {
			return nil, fmt.Errorf("mountinfo: %w", err)
		}
		mounts = append(mounts, Mount{
			Point:    point,
			FSType:   fields[sep+1],
			Writable: !hasOption(fields[5], "ro") && !hasOption(fields[sep+3], "ro"),
		})
	}
	if err := sc.Err(); err != nil {
		return nil, err
	}
	if len(mounts) == 0 {
		return nil, errors.New("mountinfo: no mounts")
	}
	return mounts, nil
}

func hasOption(options, name string) bool {
	for _, o := range strings.Split(options, ",") {
		if o == name {
			return true
		}
	}
	return false
}

// unescape decodes the octal escapes (\040 and the like) mountinfo uses for
// space, tab, newline and backslash.
func unescape(s string) (string, error) {
	if !strings.Contains(s, `\`) {
		return s, nil
	}
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		if s[i] != '\\' {
			b.WriteByte(s[i])
			continue
		}
		if i+4 > len(s) {
			return "", fmt.Errorf("truncated escape in %q", s)
		}
		n, err := strconv.ParseUint(s[i+1:i+4], 8, 8)
		if err != nil {
			return "", fmt.Errorf("bad escape in %q", s)
		}
		b.WriteByte(byte(n))
		i += 3
	}
	return b.String(), nil
}

// Roots are the places a pooled uid can leave something behind.
type Roots struct {
	// Dirs are the writable mount points walked for entries, in order.
	Dirs []string
	// Queues is the mqueue mount POSIX message queues are listed from.
	Queues string
}

// RootsOf returns the writable mount points of every filesystem that is
// neither a pseudo filesystem nor mqueue, and the first mqueue mount.
func RootsOf(mounts []Mount) Roots {
	var r Roots
	seen := map[string]bool{}
	for _, m := range mounts {
		switch {
		case m.FSType == queueFS:
			if r.Queues == "" {
				r.Queues = m.Point
			}
		case m.Writable && !pseudoFS[m.FSType] && !seen[m.Point]:
			seen[m.Point] = true
			r.Dirs = append(r.Dirs, m.Point)
		}
	}
	sort.Strings(r.Dirs)
	return r
}

// Contains reports whether path lies strictly below one of the writable
// mount points.
func (r Roots) Contains(path string) bool {
	for _, dir := range r.Dirs {
		if within(dir, path) {
			return true
		}
	}
	return false
}

func within(dir, path string) bool {
	if dir == "/" {
		return path != "/" && strings.HasPrefix(path, "/")
	}
	return strings.HasPrefix(path, dir+"/")
}

// Accounts names the pooled uids and gids.
type Accounts struct {
	UIDs map[int]bool
	GIDs map[int]bool
}

// PoolWritable reports whether a pooled uid may create entries in a
// directory with this mode and ownership: as its owner, who can always grant
// itself write permission, through the group bits when its group is a
// pooled gid, or through the bits for others.
func (a Accounts) PoolWritable(mode fs.FileMode, uid, gid int) bool {
	perm := mode.Perm()
	return a.UIDs[uid] || (a.GIDs[gid] && perm&0o020 != 0) || perm&0o002 != 0
}

// CheckMounts refuses a mount table under which a pooled uid could leave
// something where the next holder of the uid finds it outside the scope of
// Find, or where Find would not look: a writable root filesystem, a writable
// mount other than the home root whose directory the pool can write (a
// shared /tmp, /var/tmp, /run or /dev/shm), a home root that is not on a
// writable mount, or no mqueue mount to list message queues from.
func CheckMounts(mounts []Mount, homeRoot string, accounts Accounts) error {
	roots := RootsOf(mounts)
	for _, m := range mounts {
		if m.Point == "/" && m.Writable {
			return errors.New("the root filesystem is writable, so pooled uids could leave files anywhere; run with a read-only root")
		}
	}
	for _, dir := range roots.Dirs {
		if dir == homeRoot {
			continue
		}
		info, err := os.Lstat(dir)
		if err != nil || !info.IsDir() {
			continue
		}
		st, ok := info.Sys().(*syscall.Stat_t)
		if !ok {
			return fmt.Errorf("mount %s: no ownership information", dir)
		}
		if accounts.PoolWritable(info.Mode(), int(st.Uid), int(st.Gid)) {
			return fmt.Errorf("mount %s (mode %s, owner %d:%d) is writable by pooled uids; mount only the home root writable for them (no shared /tmp, /var/tmp, /run or /dev/shm; `ipc: none` removes /dev/shm)", dir, info.Mode(), st.Uid, st.Gid)
		}
	}
	if !roots.Contains(homeRoot) && !contains(roots.Dirs, homeRoot) {
		return fmt.Errorf("home root %s is not on a writable mount; mount a tmpfs there", homeRoot)
	}
	if roots.Queues == "" {
		return errors.New("no mqueue filesystem is mounted, so message queues a pooled uid leaves cannot be found; mount one at /dev/mqueue")
	}
	return nil
}

func contains(list []string, s string) bool {
	for _, v := range list {
		if v == s {
			return true
		}
	}
	return false
}

// ReadRoots reads the mount table of the calling process.
func ReadRoots() ([]Mount, Roots, error) {
	data, err := os.ReadFile("/proc/self/mountinfo")
	if err != nil {
		return nil, Roots{}, err
	}
	mounts, err := ParseMountinfo(data)
	if err != nil {
		return nil, Roots{}, err
	}
	return mounts, RootsOf(mounts), nil
}

// cleanAbs reports whether p is a clean absolute path other than "/".
func cleanAbs(p string) bool {
	return filepath.IsAbs(p) && filepath.Clean(p) == p && p != "/"
}
