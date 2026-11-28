// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package serve

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"golang.org/x/sys/unix"

	"github.com/cyfr/locus/keeper/internal/home"
	"github.com/cyfr/locus/keeper/internal/logx"
	"github.com/cyfr/locus/keeper/internal/protocol"
	"github.com/cyfr/locus/keeper/internal/vm"
)

// On a keeper that gives the wall, a disk of the directory form is retired
// whole at the start, as its uid: its homes, its work folder and its
// record, so the person signs in again in their VM; the next home made for
// them is on an image.
func TestADirectoryDiskIsRetiredWholeWhereTheWallIsGiven(t *testing.T) {
	k := keptKeeper(t)
	path := k.keptPath("vlt_old")
	if r := k.homeRequest(t, protocol.TypeHomeMake, "m1", path, testKeptFirst); r["type"] != protocol.TypeHomeMade {
		t.Fatalf("the make answered %v", r)
	}
	athanor := k.athanorOf("vlt_old")
	disk := k.s.cfg.Kept.DiskPath(athanor)
	if _, err := os.Stat(filepath.Join(disk, "programs", "vlt_old")); err != nil {
		t.Fatalf("the directory home was not made: %v", err)
	}
	k.s.wall, k.s.imageDisks = true, true
	k.s.retireDirectories()
	if _, err := os.Lstat(disk); !os.IsNotExist(err) {
		t.Fatalf("the directory disk is still there: %v", err)
	}
	if _, err := k.s.cfg.Kept.ReadDisk(athanor); !os.IsNotExist(err) {
		t.Fatalf("its record is still there: %v", err)
	}
	k.s.mu.Lock()
	indexed, homeIndexed := k.s.disks[athanor] != nil, k.s.homeDisk["vlt_old"] != ""
	k.s.mu.Unlock()
	if indexed || homeIndexed {
		t.Fatal("the keeper's index still holds the retired disk")
	}
	if _, err := os.Stat(home.Mke2fs); err != nil {
		t.Skipf("this host has no %s for the image that follows: %v", home.Mke2fs, err)
	}
	k.s.handle(k.c, &protocol.Request{V: protocol.Version, Type: protocol.TypeHomeMake, ID: "m2", Home: "vlt_old", Athanor: athanor})
	if r := k.reply(t); r["type"] != protocol.TypeHomeMade {
		t.Fatalf("the next make answered %v", r)
	}
	if d, err := k.s.cfg.Kept.ReadDisk(athanor); err != nil || d.Form != home.FormImage {
		t.Fatalf("the person's next disk is %+v %v, want an image", d, err)
	}
}

// A device of the right numbers whose mode a VMM cannot open it by gives no
// wall: KVM through its group, which is not root's, tun by anyone. A device
// node is made by root alone.
func TestADeviceAVMMCannotOpenByItsModeGivesNoWall(t *testing.T) {
	if os.Getuid() != 0 {
		t.Skip("a device node is made by root alone")
	}
	wallSeams(t)
	openDevice = func(string) error { return nil }
	dir := t.TempDir()
	node := func(name string, minor uint32, mode uint32, gid int) string {
		path := filepath.Join(dir, name)
		_ = os.Remove(path)
		if err := unix.Mknod(path, unix.S_IFCHR|mode, int(unix.Mkdev(miscMajor, minor))); err != nil {
			t.Fatal(err)
		}
		if err := os.Chmod(path, os.FileMode(mode)); err != nil {
			t.Fatal(err)
		}
		if err := os.Chown(path, 0, gid); err != nil {
			t.Fatal(err)
		}
		return path
	}
	for _, c := range []struct {
		mode uint32
		gid  int
		why  string
	}{
		{0o660, 0, "/dev/kvm's group is root's, which no VMM holds"},
		{0o600, 36, "/dev/kvm is not read and written by its group, as a VMM opens it"},
		{0o640, 36, "/dev/kvm is not read and written by its group, as a VMM opens it"},
		{0o660, 36, ""},
	} {
		if why := deviceHeld(node("kvm", kvmMinor, c.mode, c.gid), vm.KVM, kvmMinor, true); why != c.why {
			t.Errorf("KVM of mode %o and group %d: %q, want %q", c.mode, c.gid, why, c.why)
		}
	}
	for _, c := range []struct {
		mode uint32
		why  string
	}{
		{0o660, "/dev/net/tun is not read and written by everyone, as a VMM opens it"},
		{0o664, "/dev/net/tun is not read and written by everyone, as a VMM opens it"},
		{0o666, ""},
	} {
		if why := deviceHeld(node("tun", tunMinor, c.mode, 0), tunDevice, tunMinor, false); why != c.why {
			t.Errorf("tun of mode %o: %q, want %q", c.mode, why, c.why)
		}
	}
	if why := deviceHeld(node("kvm", tunMinor, 0o666, 36), vm.KVM, kvmMinor, true); why != "the container was given no /dev/kvm" {
		t.Errorf("tun at KVM's path: %q", why)
	}
}

// A keeper that gives no wall decides it whole before any disk is touched:
// for each missing piece it gives spaces, its start line says why, and a
// disk of the directory form keeps its folder and its record.
func TestAKeeperThatGivesNoWallSaysWhyAndTouchesNoDisk(t *testing.T) {
	dev := t.TempDir()
	files := []string{filepath.Join(dev, "firecracker"), filepath.Join(dev, "vmlinux")}
	for _, f := range files {
		if err := os.WriteFile(f, nil, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	wallSeams(t)
	usableDevices(t)
	routesNone := "the guard routes no machine: this kernel cannot hold a machine's route to whole IPv4 packets"
	for _, c := range []struct {
		why string
		set func(k *vmKeeper)
	}{
		{"the container was given no /dev/kvm", func(*vmKeeper) { kvmPath = "/dev/null" }},
		{"the container was given no /dev/net/tun", func(*vmKeeper) { tunPath = "/dev/null" }},
		{"/dev/net/tun does not open here: operation not permitted", func(*vmKeeper) {
			openDevice = func(path string) error {
				if path == tunDevice {
					return unix.EPERM
				}
				return nil
			}
		}},
		{routesNone, func(k *vmKeeper) { k.guard.machines = routesNone }},
		{"does not fit the work pool's", func(k *vmKeeper) { k.s.rest = 512 << 20 }},
	} {
		kvmPath, tunPath, guestFiles = vm.KVM, tunDevice, files
		openDevice = func(string) error { return nil }
		k := newVMKeeper(t)
		var log bytes.Buffer
		k.s.log = logx.NewWriter(&log, "cyfr-locus", false)
		k.s.wall, k.s.imageDisks = false, false
		k.s.roles = []*role{k.c.role}
		d := home.Disk{Athanor: "ath_dir", Form: home.FormDirectory, UID: os.Getuid(), Homes: []string{"vlt_dir"}}
		if err := k.s.putDisk(d); err != nil {
			t.Fatal(err)
		}
		folder := k.kept.HomePath("ath_dir", "vlt_dir")
		if err := os.MkdirAll(folder, 0o700); err != nil {
			t.Fatal(err)
		}
		c.set(k)
		k.s.giveWall()
		said := log.String()
		if k.s.wall || k.s.imageDisks || !strings.Contains(said, "each person's work runs in its own space on this machine: ") || !strings.Contains(said, c.why) {
			t.Errorf("%s: the wall %t, image disks %t, the keeper said %q", c.why, k.s.wall, k.s.imageDisks, said)
		}
		if _, err := os.Stat(folder); err != nil {
			t.Errorf("%s: the directory disk's home is gone: %v", c.why, err)
		}
		k.s.mu.Lock()
		got := k.s.disks["ath_dir"]
		k.s.mu.Unlock()
		if got == nil || got.Form != home.FormDirectory {
			t.Errorf("%s: the keeper's index of the directory disk is %+v", c.why, got)
		}
	}
}

// Where the wall is not given, a session of an image is refused with the
// start line's reason in its log line, never as advice to give a device
// (4742 fail 6); where it is, a reset of an image's home goes through the
// person's VM (homeInMachine's tests).
func TestAnImagesRefusalsSayWhatIsTrue(t *testing.T) {
	k := newVMKeeper(t)
	var log bytes.Buffer
	k.s.log = logx.NewWriter(&log, "cyfr-locus", false)
	k.disk(t, "ath_a", "vlt_a1")
	k.s.wall, k.s.wallWhy = false, "the container was given no /dev/net/tun"
	k.place(t, "p-s1", "ath_a")
	k.s.handleSpawn(k.c, k.spawnReq("s1", "p-s1", "vlt_a1", nil))
	if m := k.next(t); m["type"] != "error" || m["code"] != protocol.CodeUnavailable {
		t.Fatalf("a session of an image without the wall answered %v", m)
	}
	if said := log.String(); !strings.Contains(said, "this machine runs none: the container was given no /dev/net/tun") {
		t.Fatalf("a session of an image refused without the wall said %q", said)
	}
}

// At the start of a keeper that gives the wall, every never-kept disk is
// retired, no VM running: one whole, and one whose image a keeper killed in
// its retirement already took; a disk with no mark, as every record made
// before it was written is, stays.
func TestTheKeepersStartRetiresEveryNeverKeptDisk(t *testing.T) {
	dev := t.TempDir()
	files := []string{filepath.Join(dev, "firecracker"), filepath.Join(dev, "vmlinux")}
	for _, f := range files {
		if err := os.WriteFile(f, nil, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	wallSeams(t)
	usableDevices(t)
	kvmPath, tunPath, guestFiles = vm.KVM, tunDevice, files
	openDevice = func(string) error { return nil }
	k := newVMKeeper(t)
	k.s.wall, k.s.imageDisks = false, false
	k.s.roles = []*role{k.c.role}
	unkeptDisk(t, k, "ath_whole")
	unkeptDisk(t, k, "ath_halfway")
	if err := os.Remove(k.kept.ImagePath("ath_halfway")); err != nil {
		t.Fatal(err)
	}
	k.disk(t, "ath_before")
	k.s.giveWall()
	if !k.s.wall {
		t.Fatal("the test's premise: the keeper gives the wall")
	}
	if diskOf(k, "ath_whole") != nil || diskOf(k, "ath_halfway") != nil {
		t.Fatal("a never-kept disk outlived the keeper's start")
	}
	if diskOf(k, "ath_before") == nil {
		t.Fatal("a disk with no mark was retired at the keeper's start")
	}
}

// Every role's report carries the wall the keeper's start decided, in its
// three values, as giveWall set it: given only where the start gave it.
func TestAReportCarriesTheWallTheKeepersStartDecided(t *testing.T) {
	dev := t.TempDir()
	files := []string{filepath.Join(dev, "firecracker"), filepath.Join(dev, "vmlinux")}
	for _, f := range files {
		if err := os.WriteFile(f, nil, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	wallSeams(t)
	usableDevices(t)
	for _, c := range []struct {
		want string
		set  func(k *vmKeeper)
	}{
		{protocol.WallGiven, func(*vmKeeper) {}},
		{protocol.WallLacking, func(*vmKeeper) { kvmPath = "/dev/null" }},
		{protocol.WallLacking, func(*vmKeeper) { guestFiles = []string{filepath.Join(dev, "absent")} }},
		{protocol.WallLacking, func(k *vmKeeper) { k.guard.machines = "the guard routes no machine" }},
		{protocol.WallLacking, func(k *vmKeeper) { k.c.role.spec.Kept = false }},
		{protocol.WallNoRoom, func(k *vmKeeper) { k.s.rest = 512 << 20 }},
	} {
		kvmPath, tunPath, guestFiles = vm.KVM, tunDevice, files
		openDevice = func(string) error { return nil }
		k := newVMKeeper(t)
		k.s.wall, k.s.imageDisks = false, false
		k.s.roles = []*role{k.c.role}
		c.set(k)
		k.s.giveWall()
		req, perr := protocol.ParseRequest([]byte(`{"v":9,"type":"report","id":"rp","after":0}`))
		if perr != nil {
			t.Fatal(perr)
		}
		k.s.handle(k.c, req)
		got := k.expect(t, protocol.TypeReported)
		if wall := got["report"].(map[string]any)["wall"]; wall != c.want || k.s.wall != (c.want == protocol.WallGiven) {
			t.Errorf("a keeper whose start found %q reports the wall %v (it gives the wall: %t)", c.want, wall, k.s.wall)
		}
	}
}
