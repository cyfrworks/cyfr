// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package vm

import (
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"syscall"
	"time"

	"golang.org/x/sys/unix"

	"github.com/cyfr/locus/keeper/internal/proc"
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
	// MountTable is the keeper's own mounts, every one of which under the
	// root the device leaves out.
	MountTable = "/proc/self/mountinfo"
	// Mksquashfs is the maker, from the image's squashfs-tools.
	Mksquashfs = "/usr/bin/mksquashfs"
	// MakeWait bounds a start's wait for a device another start is making.
	// Warm, the making took 1.1 to 3.2 s (plan V1); cold, it is one read
	// of the image's 2.1 GB root.
	MakeWait = 3 * time.Minute
	// MakeDeadline bounds the making itself. It is below MakeWait, so a
	// start that waits from a making's beginning sees its end.
	MakeDeadline = 2 * time.Minute
)

// makerOutputWait bounds the wait, once the maker has ended, for a process
// it left outside its group that still holds its output open.
const makerOutputWait = 2 * time.Second

// ErrMaking refuses a start that waited MakeWait for the device.
var ErrMaking = errors.New("the image's programs are still being made into the machines' device")

// ErrMakeDeadline refuses a start whose making passed its deadline: the
// maker's group is killed and nothing it wrote is kept.
var ErrMakeDeadline = errors.New("the making of the machines' device passed its deadline")

var digestPattern = regexp.MustCompile(`^[0-9a-f]{64}$`)

// Maker makes the image's programs' device. Programs is the image's own;
// the fields are its paths and bounds.
type Maker struct {
	Dir    string
	Digest string
	Tool   string
	Root   string
	// Mounts is the mount table, in /proc/PID/mountinfo's form, of the
	// mount namespace Root is read in.
	Mounts string
	// Wait bounds a start's wait for another's making, Deadline the making.
	Wait     time.Duration
	Deadline time.Duration
	// Log takes the maker's own output as it is written.
	Log io.Writer
	// Start starts the maker: the keeper's own, whose reaper reaps it. It
	// is no data, so a maker written as JSON leaves it out.
	Start proc.Start `json:"-"`
}

// Programs is the keeper's maker: the container's root into ProgramsDir,
// the maker started by start.
func Programs(log io.Writer, start proc.Start) Maker {
	return Maker{Dir: ProgramsDir, Digest: DigestFile, Tool: Mksquashfs, Root: "/", Mounts: MountTable,
		Wait: MakeWait, Deadline: MakeDeadline, Log: log, Start: start}
}

// MakeArgs are the maker's flags, leave being leftOut's patterns. They are
// the wall's part: -one-file-system keeps the walk off every other
// filesystem, and leave keeps out by name every mount under the root,
// which -one-file-system's test of device numbers misses for a folder or a
// file bound from the root's own filesystem; the kept homes' volume and
// Docker's /etc/hosts, resolv.conf and hostname are among them (the image
// case holds a device to it). The guest's own files (guestFiles) are given
// as pseudo files, and the root's of their names are left out with the
// rest, as mksquashfs keeps a source's file over a pseudo file of its name.
// -e takes every argument after it, so it is last. -mem bounds the maker's
// caches inside the container's memory.
func MakeArgs(root, out string, leave []string) []string {
	args := []string{root, out, "-one-file-system", "-comp", "lz4", "-noappend", "-no-progress", "-quiet", "-mem", "256M", "-wildcards"}
	escape := strings.NewReplacer("\n", `\n`, "\t", `\t`)
	leave = slices.Clone(leave)
	for _, f := range guestFiles {
		args = append(args, "-p", f.Path+" f 644 0 0 printf '"+escape.Replace(f.Body)+"'")
		if !slices.Contains(leave, f.Path) {
			leave = append(leave, f.Path)
		}
	}
	return append(append(args, "-e"), leave...)
}

// guestFiles are the files a guest holds in place of the image's: on the
// host Docker binds them into the container, and in a guest nothing does.
// A session's space reads them from the root, as on the host: its resolver
// is at 127.0.0.11, where a routed space's two name sockets are bound in
// its own namespace (package guard), and its hosts are the loopback's.
// Neither body holds a quote or a percent sign, which the pseudo file's
// printf would read.
var guestFiles = []struct{ Path, Body string }{
	{"etc/resolv.conf", "nameserver 127.0.0.11\noptions ndots:0\n"},
	{"etc/hosts", "127.0.0.1\tlocalhost\n::1\tlocalhost ip6-localhost ip6-loopback\n"},
}

// leftOut is what of root the device leaves out, as mksquashfs -wildcards
// patterns relative to root: under every mount point in root but root
// itself, a folder's entries, so the folder stays, empty, for the guest to
// mount on, and a file whole. table is a mountinfo. A mount point inside
// another is left out with its folder's entries and never looked at (the
// container's profile denies what Docker masks under /proc and /sys); one
// that is gone is nothing to leave out.
func leftOut(root string, table []byte) ([]string, error) {
	prefix := strings.TrimSuffix(root, "/") + "/"
	var points []string
	seen := map[string]bool{}
	for line := range strings.SplitSeq(string(table), "\n") {
		if line == "" {
			continue
		}
		fields := strings.Split(line, " ")
		if len(fields) < 5 {
			return nil, fmt.Errorf("the mount table's line %q", line)
		}
		rel, ok := strings.CutPrefix(unescapeMount(fields[4]), prefix)
		if ok && rel != "" && !seen[rel] {
			seen[rel] = true
			points = append(points, rel)
		}
	}
	var leave []string
	for _, rel := range points {
		inside := false
		for dir := path.Dir(rel); dir != "." && !inside; dir = path.Dir(dir) {
			inside = seen[dir]
		}
		if inside {
			continue
		}
		point := prefix + rel
		fi, err := os.Lstat(point)
		if errors.Is(err, fs.ErrNotExist) {
			continue
		}
		if err != nil {
			return nil, fmt.Errorf("the mount point %s: %w", point, err)
		}
		pattern := escapeWildcards(rel)
		if fi.IsDir() {
			// A leading dot is matched by a pattern's own dot alone.
			leave = append(leave, pattern+"/*", pattern+"/.*")
		} else {
			leave = append(leave, pattern)
		}
	}
	return leave, nil
}

// unescapeMount decodes the octal escapes a mountinfo path carries for a
// space, a tab, a newline and a backslash.
func unescapeMount(s string) string {
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

// escapeWildcards makes a path a pattern that matches only itself. Under
// -wildcards a pattern is fnmatch's extended form, and one that begins
// "... " is unanchored; a backslashed character matches itself, so every
// ASCII character but a letter, a digit and the separator is backslashed.
func escapeWildcards(path string) string {
	var b strings.Builder
	for i := 0; i < len(path); i++ {
		c := path[i]
		if c < 0x80 && c != '/' && !('a' <= c && c <= 'z' || 'A' <= c && c <= 'Z' || '0' <= c && c <= '9') {
			b.WriteByte('\\')
		}
		b.WriteByte(c)
	}
	return b.String()
}

// Device is a start's hold on the image's programs' device: the file open
// read only under a shared lock, taken under the makers' lock, which keeps
// every call's cleanup from removing it. The machine's owner closes it at
// its VMM's end.
type Device struct {
	Path string
	f    *os.File
}

// Close ends the hold. A device no start holds is removed by the next call
// under another image.
func (d *Device) Close() error { return d.f.Close() }

// Device is this image's device, made if there is none and held for the
// caller, and whether this call made it. One maker at a time: a call that
// finds another making waits up to Wait and then refuses with ErrMaking.
// Under the same lock every call removes the temporary files a maker that
// died left and, once this image's device is held, every other release's
// that no start holds.
func (mk Maker) Device() (*Device, bool, error) {
	raw, err := os.ReadFile(mk.Digest)
	if err != nil {
		return nil, false, fmt.Errorf("the image's identity: %w", err)
	}
	digest := strings.TrimSpace(string(raw))
	if !digestPattern.MatchString(digest) {
		return nil, false, fmt.Errorf("the image's identity %q is not a sha256", digest)
	}
	lock, err := os.OpenFile(filepath.Join(mk.Dir, ".lock"), os.O_CREATE|os.O_RDWR|syscall.O_CLOEXEC, 0o600)
	if err != nil {
		return nil, false, fmt.Errorf("the machines' device's lock: %w", err)
	}
	defer lock.Close()
	if err := lockWithin(lock, mk.Wait); err != nil {
		return nil, false, err
	}
	entries, err := os.ReadDir(mk.Dir)
	if err != nil {
		return nil, false, fmt.Errorf("the machines' devices: %w", err)
	}
	for _, e := range entries {
		if strings.HasSuffix(e.Name(), ".tmp") {
			_ = os.Remove(filepath.Join(mk.Dir, e.Name()))
		}
	}
	name := digest + ".sqfs"
	path := filepath.Join(mk.Dir, name)
	made := false
	if _, err := os.Stat(path); err != nil {
		if err := mk.make(path); err != nil {
			return nil, false, err
		}
		made = true
	}
	f, err := os.Open(path)
	if err != nil {
		return nil, false, fmt.Errorf("the machines' device: %w", err)
	}
	// No exclusive lock on a device is taken but under the makers' lock.
	if err := unix.Flock(int(f.Fd()), unix.LOCK_SH|unix.LOCK_NB); err != nil {
		_ = f.Close()
		return nil, false, fmt.Errorf("the machines' device's hold: %w", err)
	}
	for _, e := range entries {
		if other := e.Name(); strings.HasSuffix(other, ".sqfs") && other != name {
			removeUnheld(filepath.Join(mk.Dir, other))
		}
	}
	return &Device{Path: path, f: f}, made, nil
}

// removeUnheld removes another release's device unless a start holds it,
// keeping its exclusive lock across the removal.
func removeUnheld(path string) {
	f, err := os.Open(path)
	if err != nil {
		return
	}
	defer f.Close()
	if unix.Flock(int(f.Fd()), unix.LOCK_EX|unix.LOCK_NB) == nil {
		_ = os.Remove(path)
	}
}

// make writes the device to a temporary name, syncs it and renames it
// whole.
func (mk Maker) make(path string) error {
	root, err := filepath.EvalSymlinks(mk.Root)
	if err != nil {
		return fmt.Errorf("making the machines' device: %w", err)
	}
	table, err := os.ReadFile(mk.Mounts)
	if err != nil {
		return fmt.Errorf("making the machines' device: the mount table: %w", err)
	}
	leave, err := leftOut(root, table)
	if err != nil {
		return fmt.Errorf("making the machines' device: %w", err)
	}
	tmp := path + ".tmp"
	if err := mk.run(MakeArgs(root, tmp, leave)); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	f, err := os.Open(tmp)
	if err == nil {
		err = f.Sync()
		_ = f.Close()
	}
	if err == nil {
		// Every machine's VMM reads it under a uid of its own, and only the
		// keeper writes it: it holds the image's programs, which every space
		// reads already.
		err = os.Chmod(tmp, 0o644)
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

// run runs the maker within Deadline, started by mk.Start. It leads a
// process group of its own, which a passed deadline kills whole before the
// leader is reaped, while the group's id can still be no other's.
func (mk Maker) run(args []string) error {
	if mk.Start == nil {
		return errors.New("making the machines' device: the maker has no start")
	}
	err := proc.Run(mk.Start, mk.Tool, append([]string{filepath.Base(mk.Tool)}, args...), []string{"PATH=/usr/bin:/bin"},
		&syscall.SysProcAttr{Setpgid: true, Pdeathsig: syscall.SIGKILL}, mk.Log, mk.Deadline, makerOutputWait)
	switch {
	case errors.Is(err, proc.ErrDeadline):
		return fmt.Errorf("%w (%s)", ErrMakeDeadline, mk.Deadline)
	case err != nil:
		return fmt.Errorf("making the machines' device: %w", err)
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
