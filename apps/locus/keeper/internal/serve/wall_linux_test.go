// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package serve

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/cyfr/locus/keeper/internal/home"
	"github.com/cyfr/locus/keeper/internal/protocol"
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
