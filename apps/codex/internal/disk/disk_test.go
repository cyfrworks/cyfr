// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package disk

import (
	"cmp"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"testing"
)

// fixture is a fake machine: a mountinfo table, a sysfs tree under its root
// and the device numbers its Stat reports.
type fixture struct {
	t     *testing.T
	root  string
	lines []string
	devs  map[string]string
}

func newFixture(t *testing.T) *fixture {
	return &fixture{t: t, root: t.TempDir(), devs: map[string]string{}}
}

func (f *fixture) sys(elem ...string) string {
	return filepath.Join(append([]string{f.root, "sys"}, elem...)...)
}

func (f *fixture) write(path, content string) {
	f.t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		f.t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		f.t.Fatal(err)
	}
}

func (f *fixture) mkdir(path string) {
	f.t.Helper()
	if err := os.MkdirAll(path, 0o755); err != nil {
		f.t.Fatal(err)
	}
}

// link makes a relative symlink at path to target, as sysfs does.
func (f *fixture) link(path, target string) {
	f.t.Helper()
	f.mkdir(filepath.Dir(path))
	rel, err := filepath.Rel(filepath.Dir(path), target)
	if err != nil {
		f.t.Fatal(err)
	}
	if err := os.Symlink(rel, path); err != nil {
		f.t.Fatal(err)
	}
}

// block makes the sysfs directory of the block device numbered dev at rel
// under devices/, with an empty slaves directory and its dev/block link.
func (f *fixture) block(rel, dev string) string {
	dir := f.sys("devices", rel)
	f.mkdir(filepath.Join(dir, "slaves"))
	f.link(f.sys("dev", "block", dev), dir)
	return dir
}

func (f *fixture) disk(name, dev string) string {
	return f.block("pci0000:00/block/"+name, dev)
}

func (f *fixture) part(disk, name, dev string) string {
	rel, err := filepath.Rel(f.sys("devices"), filepath.Join(disk, name))
	if err != nil {
		f.t.Fatal(err)
	}
	dir := f.block(rel, dev)
	f.write(filepath.Join(dir, "partition"), "1\n")
	return dir
}

func (f *fixture) dm(name, dev, uuid string, lower ...string) string {
	dir := f.block("virtual/block/"+name, dev)
	f.write(filepath.Join(dir, "dm", "uuid"), uuid+"\n")
	f.stack(dir, lower...)
	return dir
}

func (f *fixture) md(name, dev string, lower ...string) string {
	dir := f.block("virtual/block/"+name, dev)
	f.mkdir(filepath.Join(dir, "md"))
	f.stack(dir, lower...)
	return dir
}

func (f *fixture) loop(name, dev, backing string) string {
	dir := f.block("virtual/block/"+name, dev)
	f.mkdir(filepath.Join(dir, "loop"))
	if backing != "" {
		f.write(filepath.Join(dir, "loop", "backing_file"), backing+"\n")
	}
	return dir
}

func (f *fixture) stack(dir string, lower ...string) {
	for _, l := range lower {
		f.link(filepath.Join(dir, "slaves", filepath.Base(l)), l)
	}
}

// mount adds a mountinfo line, escaping the mount point as the kernel does.
func (f *fixture) mount(dev, point, fstype, source string) {
	n := len(f.lines)
	f.lines = append(f.lines, fmt.Sprintf("%d 1 %s / %s rw,relatime shared:%d - %s %s rw",
		20+n, dev, strings.ReplaceAll(point, " ", `\040`), n+1, fstype, source))
}

// stat records the device number Stat reports for path; other paths fail.
func (f *fixture) stat(path, dev string) { f.devs[path] = dev }

func (f *fixture) system() System {
	f.t.Helper()
	mountinfo := filepath.Join(f.root, "mountinfo")
	f.write(mountinfo, strings.Join(f.lines, "\n")+"\n")
	return System{MountInfo: mountinfo, Sys: f.sys(), Stat: func(path string) (uint32, uint32, error) {
		dev, ok := f.devs[path]
		if !ok {
			return 0, 0, fs.ErrNotExist
		}
		majorText, minorText, _ := strings.Cut(dev, ":")
		major, _ := strconv.ParseUint(majorText, 10, 32)
		minor, _ := strconv.ParseUint(minorText, 10, 32)
		return uint32(major), uint32(minor), nil
	}}
}

const luks = "CRYPT-LUKS2-0a1b2c3d4e5f60718293a4b5c6d7e8f9-root"

// encryptedRoot mounts / on a LUKS2 mapping of sda2, with /boot on plain sda1.
func encryptedRoot(f *fixture) (sda string) {
	sda = f.disk("sda", "8:0")
	f.part(sda, "sda1", "8:1")
	f.dm("dm-0", "253:0", luks, f.part(sda, "sda2", "8:2"))
	f.mount("253:0", "/", "ext4", "/dev/mapper/root")
	f.mount("8:1", "/boot", "ext4", "/dev/sda1")
	f.stat("/", "253:0")
	return sda
}

// plainSecondDisk makes sdb with partition sdb1 (8:17), unmounted.
func plainSecondDisk(f *fixture) {
	f.part(f.disk("sdb", "8:16"), "sdb1", "8:17")
	f.stat("/dev/sdb1", "8:17")
}

// stackedOnCrypt mounts / on n LVM mappings stacked over a LUKS2 mapping.
func stackedOnCrypt(f *fixture, n int) {
	lower := f.dm("dm-0", "253:0", luks, f.part(f.disk("sda", "8:0"), "sda2", "8:2"))
	for i := 1; i <= n; i++ {
		lower = f.dm(fmt.Sprintf("dm-%d", i), fmt.Sprintf("253:%d", i), fmt.Sprintf("LVM-%032d", i), lower)
	}
	f.mount(fmt.Sprintf("253:%d", n), "/", "ext4", "/dev/mapper/top")
	f.stat("/", fmt.Sprintf("253:%d", n))
	f.stat(dataDir, fmt.Sprintf("253:%d", n))
}

const dataDir = "/home/u/cyfr/data"

var (
	encEnc   = Report{Root: Encrypted, Data: Encrypted}
	encPlain = Report{Root: Encrypted, Data: Unencrypted}
	encUnk   = Report{Root: Encrypted, Data: Unknown}
	plain    = Report{Root: Unencrypted, Data: Unencrypted}
	unknown  = Report{Root: Unknown, Data: Unknown}
)

var cases = []struct {
	name  string
	data  string // dataDir when empty
	setup func(f *fixture)
	want  Report
}{
	{"root on LUKS2 over a partition, data under root", "", func(f *fixture) {
		encryptedRoot(f)
		f.stat(dataDir, "253:0")
	}, encEnc},
	{"root on LVM over LUKS2", "", func(f *fixture) {
		crypt := f.dm("dm-0", "253:0", luks, f.part(f.disk("sda", "8:0"), "sda3", "8:3"))
		f.dm("dm-1", "253:1", "LVM-MKKBrimtdEavYPtfxhzWDo3OvDGeQLmj0po2MWNkul6A1gKmWYHxXfiyhk3FGbp9", crypt)
		f.mount("253:1", "/", "ext4", "/dev/mapper/vg-root")
		f.stat("/", "253:1")
		f.stat(dataDir, "253:1")
	}, encEnc},
	{"root on a plain partition, data under root", "", func(f *fixture) {
		f.part(f.disk("nvme0n1", "259:0"), "nvme0n1p2", "259:2")
		f.mount("259:2", "/", "ext4", "/dev/nvme0n1p2")
		f.stat("/", "259:2")
		f.stat(dataDir, "259:2")
	}, plain},
	{"data on a separate plain disk", "/srv/cyfr/data", func(f *fixture) {
		encryptedRoot(f)
		plainSecondDisk(f)
		f.mount("8:17", "/srv", "ext4", "/dev/sdb1")
		f.stat("/srv/cyfr/data", "8:17")
	}, encPlain},
	{"data in an unmounted btrfs subvolume on a separate plain disk", "/srv/cyfr/data", func(f *fixture) {
		encryptedRoot(f)
		plainSecondDisk(f)
		f.mount("0:45", "/srv", "btrfs", "/dev/sdb1")
		f.stat("/srv/cyfr/data", "0:99")
	}, encPlain},
	{"data under a mount point with a space", "/srv/my disk/data", func(f *fixture) {
		encryptedRoot(f)
		plainSecondDisk(f)
		f.mount("0:45", "/srv/my disk", "btrfs", "/dev/sdb1")
		f.stat("/srv/my disk/data", "0:99")
	}, encPlain},
	{"data whose path is under root but whose device is a plain disk", "", func(f *fixture) {
		encryptedRoot(f)
		plainSecondDisk(f)
		f.mount("8:17", "/mnt/usb", "ext4", "/dev/sdb1")
		f.stat(dataDir, "8:17")
	}, encPlain},
	{"btrfs root on LUKS2, through its mount source", "", func(f *fixture) {
		f.dm("dm-0", "253:0", luks, f.part(f.disk("sda", "8:0"), "sda2", "8:2"))
		f.mount("0:30", "/", "btrfs", "/dev/mapper/root")
		f.stat("/", "0:30")
		f.stat("/dev/mapper/root", "253:0")
		f.stat(dataDir, "0:31")
	}, encEnc},
	{"data on tmpfs", "/run/cyfr/data", func(f *fixture) {
		encryptedRoot(f)
		f.mount("0:50", "/run/cyfr", "tmpfs", "tmpfs")
		f.stat("/run/cyfr/data", "0:50")
	}, encUnk},
	{"data on overlay", "/var/lib/cyfr/data", func(f *fixture) {
		encryptedRoot(f)
		f.mount("0:60", "/var/lib/cyfr", "overlay", "overlay")
		f.stat("/var/lib/cyfr/data", "0:60")
	}, encUnk},
	{"a missing data directory", "", func(f *fixture) {
		encryptedRoot(f)
	}, encUnk},
	{"a device missing from sysfs", "", func(f *fixture) {
		f.mount("8:2", "/", "ext4", "/dev/sda2")
		f.stat("/", "8:2")
		f.stat(dataDir, "8:2")
	}, unknown},
	{"RAID1 of an encrypted and a plain member", "", func(f *fixture) {
		sda := f.disk("sda", "8:0")
		crypt := f.dm("dm-0", "253:0", luks, f.part(sda, "sda1", "8:1"))
		f.md("md0", "9:0", crypt, f.part(f.disk("sdb", "8:16"), "sdb1", "8:17"))
		f.mount("9:0", "/", "ext4", "/dev/md0")
		f.stat("/", "9:0")
		f.stat(dataDir, "9:0")
	}, plain},
	{"RAID1 of two encrypted members", "", func(f *fixture) {
		a := f.dm("dm-0", "253:0", luks, f.part(f.disk("sda", "8:0"), "sda1", "8:1"))
		b := f.dm("dm-1", "253:1", "CRYPT-LUKS2-ffeeddccbbaa99887766554433221100-b", f.part(f.disk("sdb", "8:16"), "sdb1", "8:17"))
		f.md("md0", "9:0", a, b)
		f.mount("9:0", "/", "ext4", "/dev/md0")
		f.stat("/", "9:0")
		f.stat(dataDir, "9:0")
	}, encEnc},
	{"RAID1 of an encrypted member and a missing one", "", func(f *fixture) {
		crypt := f.dm("dm-0", "253:0", luks, f.part(f.disk("sda", "8:0"), "sda1", "8:1"))
		f.md("md0", "9:0", crypt, f.sys("devices", "pci0000:00", "block", "sdb", "sdb1"))
		f.mount("9:0", "/", "ext4", "/dev/md0")
		f.stat("/", "9:0")
		f.stat(dataDir, "9:0")
	}, unknown},
	{"LVM over a missing PV and a plain one", "", func(f *fixture) {
		missing := f.sys("devices", "pci0000:00", "block", "sda", "sda1")
		f.dm("dm-0", "253:0", "LVM-abc", missing, f.part(f.disk("sdb", "8:16"), "sdb1", "8:17"))
		f.mount("253:0", "/", "ext4", "/dev/mapper/vg-root")
		f.stat("/", "253:0")
		f.stat(dataDir, "253:0")
	}, plain},
	{"a mapping with no dm uuid", "", func(f *fixture) {
		dir := f.dm("dm-0", "253:0", luks, f.part(f.disk("sda", "8:0"), "sda2", "8:2"))
		if err := os.Remove(filepath.Join(dir, "dm", "uuid")); err != nil {
			f.t.Fatal(err)
		}
		f.mount("253:0", "/", "ext4", "/dev/mapper/root")
		f.stat("/", "253:0")
		f.stat(dataDir, "253:0")
	}, unknown},
	{"dm-verity over plain partitions", "", func(f *fixture) {
		sda := f.disk("sda", "8:0")
		f.dm("dm-0", "253:0", "CRYPT-VERITY-0a1b2c3d-root", f.part(sda, "sda2", "8:2"), f.part(sda, "sda3", "8:3"))
		f.mount("253:0", "/", "erofs", "/dev/mapper/root")
		f.stat("/", "253:0")
		f.stat(dataDir, "253:0")
	}, plain},
	{"data in a loop image on the encrypted root", "/srv/data", func(f *fixture) {
		encryptedRoot(f)
		f.loop("loop0", "7:0", "/var/lib/cyfr.img")
		f.mount("7:0", "/srv", "ext4", "/dev/loop0")
		f.stat("/srv/data", "7:0")
		f.stat("/var/lib/cyfr.img", "253:0")
	}, encEnc},
	{"data in a loop image on a plain disk", "/srv/data", func(f *fixture) {
		encryptedRoot(f)
		plainSecondDisk(f)
		f.mount("8:17", "/mnt/usb", "ext4", "/dev/sdb1")
		f.loop("loop0", "7:0", "/mnt/usb/cyfr.img")
		f.mount("7:0", "/srv", "ext4", "/dev/loop0")
		f.stat("/srv/data", "7:0")
		f.stat("/mnt/usb/cyfr.img", "8:17")
	}, encPlain},
	{"data on a loop device with no backing file", "/srv/data", func(f *fixture) {
		encryptedRoot(f)
		f.loop("loop0", "7:0", "")
		f.mount("7:0", "/srv", "ext4", "/dev/loop0")
		f.stat("/srv/data", "7:0")
	}, encUnk},
	{"a mapping stacked on itself", "", func(f *fixture) {
		dir := f.dm("dm-0", "253:0", "LVM-abc")
		f.stack(dir, dir)
		f.mount("253:0", "/", "ext4", "/dev/mapper/vg-root")
		f.stat("/", "253:0")
		f.stat(dataDir, "253:0")
	}, unknown},
	{"16 devices deep", "", func(f *fixture) { stackedOnCrypt(f, 15) }, encEnc},
	{"17 devices deep", "", func(f *fixture) { stackedOnCrypt(f, 16) }, unknown},
}

func TestDetect(t *testing.T) {
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			f := newFixture(t)
			c.setup(f)
			data := cmp.Or(c.data, dataDir)
			if got := f.system().Detect("/", data); got != c.want {
				t.Errorf("Detect(/, %s) = %+v, want %+v", data, got, c.want)
			}
		})
	}
}

// TestDetectWritesNothing runs every case and compares the whole fixture tree,
// names, modes, times, link targets and contents, before and after.
func TestDetectWritesNothing(t *testing.T) {
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			f := newFixture(t)
			c.setup(f)
			s := f.system()
			before := snapshot(t, f.root)
			s.Detect("/", cmp.Or(c.data, dataDir))
			after := snapshot(t, f.root)
			for p, v := range before {
				if after[p] != v {
					t.Errorf("%s changed: %q -> %q", p, v, after[p])
				}
			}
			for p, v := range after {
				if _, ok := before[p]; !ok {
					t.Errorf("%s created: %q", p, v)
				}
			}
		})
	}
}

func TestDetectWithoutAMountTable(t *testing.T) {
	f := newFixture(t)
	encryptedRoot(f)
	f.stat(dataDir, "253:0")
	s := f.system()
	if got := s.Detect("/", dataDir); got != encEnc {
		t.Fatalf("control: Detect = %+v, want %+v", got, encEnc)
	}

	missing := s
	missing.MountInfo = filepath.Join(f.root, "absent")
	if got := missing.Detect("/", dataDir); got != unknown {
		t.Errorf("unreadable mountinfo: Detect = %+v, want %+v", got, unknown)
	}

	f.lines = append(f.lines, "99 1 8:1 / /srv")
	if got := f.system().Detect("/", dataDir); got != unknown {
		t.Errorf("malformed mountinfo: Detect = %+v, want %+v", got, unknown)
	}
}

func TestCapabilities(t *testing.T) {
	for r, want := range map[Report][]string{
		{Root: Encrypted, Data: Unknown}:     {"root_encrypted", "data_unknown"},
		{Root: Unencrypted, Data: Encrypted}: {"root_unencrypted", "data_encrypted"},
		{Root: Unknown, Data: Unencrypted}:   {"root_unknown", "data_unencrypted"},
	} {
		if got := r.Capabilities(); !slices.Equal(got, want) {
			t.Errorf("%+v.Capabilities() = %q, want %q", r, got, want)
		}
	}
}

func snapshot(t *testing.T, root string) map[string]string {
	t.Helper()
	out := map[string]string{}
	err := filepath.WalkDir(root, func(p string, e fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		info, err := e.Info()
		if err != nil {
			return err
		}
		v := fmt.Sprintf("%v %d", info.Mode(), info.ModTime().UnixNano())
		switch {
		case info.Mode()&fs.ModeSymlink != 0:
			target, err := os.Readlink(p)
			if err != nil {
				return err
			}
			v += " -> " + target
		case info.Mode().IsRegular():
			b, err := os.ReadFile(p)
			if err != nil {
				return err
			}
			v += " " + string(b)
		}
		out[p] = v
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return out
}
