// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package home

import (
	"encoding/binary"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

// needMke2fs skips where the host has no mke2fs (the real-kernel step's Go
// container); the runner's own step has it.
func needMke2fs(t *testing.T) {
	t.Helper()
	if _, err := os.Stat(Mke2fs); err != nil {
		t.Skipf("this host has no %s: %v", Mke2fs, err)
	}
}

// temporaries is every image temporary left under root.
func temporaries(t *testing.T, root string) []string {
	t.Helper()
	m, err := filepath.Glob(filepath.Join(root, ".*"+ImageSuffix+".*"))
	if err != nil {
		t.Fatal(err)
	}
	return m
}

// A person's disk image is one sparse ext4 file directly under the kept
// root, named by the person, of the keeper's uid and the VMMs' group with
// ImageMode, ImageBytes long though it holds far less, and made once: a
// second ensure changes nothing.
func TestADisksImageIsASparseExt4FileMadeOnce(t *testing.T) {
	needMke2fs(t)
	k := keptOfMine(t, 1)
	if err := k.EnsureImage("ath_1", os.Getuid(), os.Getgid()); err != nil {
		t.Fatal(err)
	}
	path := k.ImagePath("ath_1")
	if path != filepath.Join(k.Root, Person("ath_1")+".img") {
		t.Fatalf("the image is at %s", path)
	}
	info, err := os.Lstat(path)
	if err != nil {
		t.Fatal(err)
	}
	st := info.Sys().(*syscall.Stat_t)
	switch {
	case !info.Mode().IsRegular() || info.Mode().Perm() != ImageMode:
		t.Fatalf("the image is %s, not a regular file of %o", info.Mode(), ImageMode)
	case int(st.Uid) != os.Getuid() || int(st.Gid) != os.Getgid():
		t.Fatalf("the image is %d:%d", st.Uid, st.Gid)
	case info.Size() != ImageBytes:
		t.Fatalf("the image is %d bytes long, not %d", info.Size(), ImageBytes)
	case st.Blocks*512 > 256<<20:
		t.Fatalf("the image holds %d bytes of the volume: it is not sparse", st.Blocks*512)
	}
	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	magic := make([]byte, 2)
	_, err = f.ReadAt(magic, 1024+56)
	f.Close()
	if err != nil || binary.LittleEndian.Uint16(magic) != 0xEF53 {
		t.Fatalf("the image holds no ext4 superblock: %x %v", magic, err)
	}
	before := st.Ino
	mtime := info.ModTime()
	if err := k.EnsureImage("ath_1", os.Getuid(), os.Getgid()); err != nil {
		t.Fatal(err)
	}
	again, err := os.Lstat(path)
	if err != nil || again.Sys().(*syscall.Stat_t).Ino != before || !again.ModTime().Equal(mtime) {
		t.Fatalf("a second ensure made the image again: %v", err)
	}
	if left := temporaries(t, k.Root); len(left) != 0 {
		t.Fatalf("the making left %v", left)
	}
}

// A making that fails, or outlives its bound, leaves no image and no
// temporary; one past its bound is killed with its process group.
func TestAFailedMakingLeavesNoImage(t *testing.T) {
	saved, savedWait := Mke2fs, MakeImageWait
	t.Cleanup(func() { Mke2fs, MakeImageWait = saved, savedWait })
	dir := t.TempDir()
	pidFile := filepath.Join(dir, "child")
	slow := filepath.Join(dir, "slow-mke2fs")
	// sleep-ok: the stand-in maker outlives the making's shortened bound,
	// which ends it with the child it started.
	script := "#!/bin/sh\nsleep 30 &\necho $! > " + pidFile + "\nwait\n"
	if err := os.WriteFile(slow, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct {
		maker string
		wait  time.Duration
		why   string
	}{{"/bin/false", time.Minute, "mke2fs: exit status 1"}, {slow, 300 * time.Millisecond, "did not finish within 300ms"}} {
		Mke2fs, MakeImageWait = c.maker, c.wait
		k := keptOfMine(t, 1)
		began := time.Now()
		err := k.EnsureImage("ath_1", os.Getuid(), os.Getgid())
		if err == nil || !strings.Contains(err.Error(), c.why) {
			t.Fatalf("%s: the making answered %v", c.maker, err)
		}
		// Its bound holds whatever the maker started: a child left alive
		// would hold its output, and the making, open past it.
		if took := time.Since(began); took > c.wait+5*time.Second {
			t.Fatalf("%s: the making took %s, past its bound %s", c.maker, took, c.wait)
		}
		if _, err := os.Lstat(k.ImagePath("ath_1")); !os.IsNotExist(err) {
			t.Fatalf("%s: a failed making left an image: %v", c.maker, err)
		}
		if left := temporaries(t, k.Root); len(left) != 0 {
			t.Fatalf("%s: a failed making left %v", c.maker, left)
		}
	}
	raw, err := os.ReadFile(pidFile)
	if err != nil {
		t.Fatal(err)
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(raw)))
	if err != nil {
		t.Fatal(err)
	}
	// Killed, it is gone once whoever adopted it has reaped it.
	for deadline := time.Now().Add(5 * time.Second); syscall.Kill(pid, 0) == nil; {
		if time.Now().After(deadline) {
			t.Fatalf("the maker's child %d outlived the making's bound", pid)
		}
		time.Sleep(10 * time.Millisecond) // sleep-ok: a bounded wait for the killed child's reaping
	}
}

// LoadDisks takes a record of an image, removes what a dead making left,
// and still refuses a form it does not know.
func TestTheRecordsTakeAnImageAndRemoveADeadMakingsTemporary(t *testing.T) {
	k := recordsOfMine(t, 2)
	if _, err := k.LoadDisks(); err != nil {
		t.Fatal(err)
	}
	d := Disk{Athanor: "ath_1", Form: FormImage, UID: os.Getuid(), Homes: []string{"vlt_a"}}
	if err := k.WriteDisk(d); err != nil {
		t.Fatal(err)
	}
	left := filepath.Join(k.Root, "."+Person("ath_1")+ImageSuffix+".123456")
	other := filepath.Join(k.Root, ".not-a-person.img.1")
	for _, f := range []string{left, other} {
		if err := os.WriteFile(f, nil, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	disks, err := k.LoadDisks()
	if err != nil {
		t.Fatal(err)
	}
	if got := disks["ath_1"]; got == nil || got.Form != FormImage || !got.Holds("vlt_a") {
		t.Fatalf("the image's record read %+v", got)
	}
	if _, err := os.Lstat(left); !os.IsNotExist(err) {
		t.Fatalf("a dead making's temporary stays: %v", err)
	}
	if _, err := os.Lstat(other); err != nil {
		t.Fatalf("a file not of a making was removed: %v", err)
	}
	d.Form = "volume"
	if err := k.WriteDisk(d); err != nil {
		t.Fatal(err)
	}
	if _, err := k.LoadDisks(); err == nil || !strings.Contains(err.Error(), `has form "volume"`) {
		t.Fatalf("a record of an unknown form answered %v", err)
	}
}
