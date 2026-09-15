// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package residue

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// A container's mount table as Docker writes it for the bridge service.
const dockerMountinfo = `135 84 0:62 / / ro,relatime - overlay overlay rw,lowerdir=/l,upperdir=/u,workdir=/w
137 135 0:71 / /proc rw,nosuid,nodev,noexec,relatime - proc proc rw
138 135 0:72 / /dev rw,nosuid - tmpfs tmpfs rw,size=65536k,mode=755
139 138 0:73 / /dev/pts rw,nosuid,noexec,relatime - devpts devpts rw,gid=5,mode=620,ptmxmode=666
140 135 0:74 / /sys ro,nosuid,nodev,noexec,relatime - sysfs sysfs ro
141 140 0:39 / /sys/fs/cgroup ro,nosuid,nodev,noexec,relatime - cgroup2 cgroup rw
142 138 0:69 / /dev/mqueue rw,nosuid,nodev,noexec,relatime - mqueue mqueue rw
144 135 0:75 / /run/cyfr-bridge rw,nosuid,nodev,noexec,relatime - tmpfs tmpfs rw,mode=700,uid=10001,gid=10001
145 135 254:1 /docker/containers/c/resolv.conf /etc/resolv.conf ro,relatime - ext4 /dev/vda1 rw,discard
148 135 0:76 / /var/lib/cyfr-bridge/homes rw,nosuid,nodev,relatime - tmpfs tmpfs rw,mode=1733
90 137 0:72 /null /proc/interrupts rw,nosuid - tmpfs tmpfs rw,size=65536k,mode=755
93 137 0:77 / /proc/scsi ro,relatime - tmpfs tmpfs ro
96 135 0:78 / /mnt/with\040space rw,relatime shared:1 master:2 - tmpfs tmpfs rw
97 135 0:79 / /mnt/ro-super rw,relatime - ext4 /dev/vdb ro
`

func TestParseMountinfoReadsPointsTypesAndWritability(t *testing.T) {
	mounts, err := ParseMountinfo([]byte(dockerMountinfo))
	if err != nil {
		t.Fatal(err)
	}
	byPoint := map[string]Mount{}
	for _, m := range mounts {
		byPoint[m.Point] = m
	}
	for point, want := range map[string]Mount{
		"/":                          {Point: "/", FSType: "overlay", Writable: false},
		"/dev/mqueue":                {Point: "/dev/mqueue", FSType: "mqueue", Writable: true},
		"/var/lib/cyfr-bridge/homes": {Point: "/var/lib/cyfr-bridge/homes", FSType: "tmpfs", Writable: true},
		"/mnt/with space":            {Point: "/mnt/with space", FSType: "tmpfs", Writable: true},
		"/mnt/ro-super":              {Point: "/mnt/ro-super", FSType: "ext4", Writable: false},
		"/sys/fs/cgroup":             {Point: "/sys/fs/cgroup", FSType: "cgroup2", Writable: false},
	} {
		if got := byPoint[point]; got != want {
			t.Errorf("%s: got %+v, want %+v", point, got, want)
		}
	}

	for _, bad := range []string{"1 2 3:4 / /x rw", "1 2 3:4 / /x rw - tmpfs", "1 2 3:4 / /x\\04 rw - tmpfs tmpfs rw"} {
		if _, err := ParseMountinfo([]byte(bad)); err == nil {
			t.Errorf("%q: accepted", bad)
		}
	}
}

func TestRootsAreTheWritableRealFilesystemsAndTheQueueMount(t *testing.T) {
	mounts, err := ParseMountinfo([]byte(dockerMountinfo))
	if err != nil {
		t.Fatal(err)
	}
	roots := RootsOf(mounts)
	want := Roots{
		Dirs:   []string{"/dev", "/mnt/with space", "/proc/interrupts", "/run/cyfr-bridge", "/var/lib/cyfr-bridge/homes"},
		Queues: "/dev/mqueue",
	}
	if !reflect.DeepEqual(roots, want) {
		t.Fatalf("roots\n got %+v\nwant %+v", roots, want)
	}
	for path, inside := range map[string]bool{
		"/var/lib/cyfr-bridge/homes/20001-x": true,
		"/var/lib/cyfr-bridge/homes":         false,
		"/var/lib/cyfr-bridge/homesick":      false,
		"/dev/mqueue/q":                      true,
		"/etc/passwd":                        false,
	} {
		if roots.Contains(path) != inside {
			t.Errorf("Contains(%s) = %t", path, !inside)
		}
	}
}

func TestPoolWritableCountsOwnershipGroupAndOthers(t *testing.T) {
	a := Accounts{UIDs: map[int]bool{20001: true}, GIDs: map[int]bool{20001: true}}
	for _, c := range []struct {
		mode     os.FileMode
		uid, gid int
		want     bool
	}{
		{0o755, 0, 0, false},
		{0o700, 10001, 10001, false},
		{0o1733, 0, 0, true},
		{0o1777, 0, 0, true},
		{0o500, 20001, 0, true},
		{0o770, 0, 20001, true},
		{0o750, 0, 20001, false},
	} {
		if got := a.PoolWritable(c.mode, c.uid, c.gid); got != c.want {
			t.Errorf("mode %o owner %d:%d: got %t", c.mode, c.uid, c.gid, got)
		}
	}
}

func TestCheckMountsRefusesSharedWritableLocations(t *testing.T) {
	dir := t.TempDir()
	mkdir := func(name string, mode os.FileMode) string {
		p := filepath.Join(dir, name)
		if err := os.Mkdir(p, 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.Chmod(p, mode); err != nil {
			t.Fatal(err)
		}
		return p
	}
	homes := mkdir("homes", os.ModeSticky|0o733)
	attach := mkdir("attach", 0o700)
	shared := mkdir("shared", os.ModeSticky|0o777)
	queues := mkdir("mqueue", os.ModeSticky|0o777)
	defer os.Chmod(shared, 0o700)

	nobody := Accounts{UIDs: map[int]bool{}, GIDs: map[int]bool{}}
	table := func(lines ...string) []Mount {
		var mounts []Mount
		for _, l := range lines {
			fields := strings.SplitN(l, " ", 3)
			mounts = append(mounts, Mount{Point: fields[0], FSType: fields[1], Writable: fields[2] == "rw"})
		}
		return mounts
	}
	good := []string{"/ overlay ro", homes + " tmpfs rw", attach + " tmpfs rw", queues + " mqueue rw"}

	if err := CheckMounts(table(good...), homes, nobody); err != nil {
		t.Fatalf("the compose mount table was refused: %v", err)
	}

	cases := map[string]struct {
		mounts   []Mount
		homeRoot string
		accounts Accounts
		want     string
	}{
		"a writable root":            {table(append([]string{"/ overlay rw"}, good[1:]...)...), homes, nobody, "root filesystem is writable"},
		"a shared writable mount":    {table(append(good, shared+" tmpfs rw")...), homes, nobody, "writable by pooled uids"},
		"a mount a pooled uid owns":  {table(good...), homes, Accounts{UIDs: map[int]bool{os.Getuid(): true}, GIDs: map[int]bool{}}, "writable by pooled uids"},
		"a home root on no mount":    {table(good[0], attach+" tmpfs rw", queues+" mqueue rw"), homes, nobody, "not on a writable mount"},
		"a read-only home root":      {table(good[0], homes+" tmpfs ro", attach+" tmpfs rw", queues+" mqueue rw"), homes, nobody, "not on a writable mount"},
		"no mqueue mount":            {table(good[:3]...), homes, nobody, "no mqueue"},
		"a home root below a mount":  {table(good[0], dir+" tmpfs rw", queues+" mqueue rw"), homes, nobody, ""},
		"a read-only shared mount":   {table(append(good, shared+" tmpfs ro")...), homes, nobody, ""},
		"a shared pseudo filesystem": {table(append(good, shared+" devpts rw")...), homes, nobody, ""},
	}
	for name, c := range cases {
		err := CheckMounts(c.mounts, c.homeRoot, c.accounts)
		switch {
		case c.want == "" && err != nil:
			t.Errorf("%s: refused: %v", name, err)
		case c.want != "" && (err == nil || !strings.Contains(err.Error(), c.want)):
			t.Errorf("%s: got %v, want an error containing %q", name, err, c.want)
		}
	}
}
