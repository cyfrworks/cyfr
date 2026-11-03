// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package disk

import "testing"

func TestDetect_ABtrfsSourceAloneIsNotEncryption(t *testing.T) {
	f := newFixture(t)
	crypt := f.dm("dm-0", "253:0", luks, f.part(f.disk("sda", "8:0"), "sda2", "8:2"))
	plain := f.part(f.disk("sdb", "8:16"), "sdb1", "8:17")
	f.link(f.sys("fs", "btrfs", "example-fsid", "devices", "dm-0"), crypt)
	f.link(f.sys("fs", "btrfs", "example-fsid", "devices", "sdb1"), plain)
	f.mount("0:30", "/", "btrfs", "/dev/mapper/root")
	f.stat("/", "0:30")
	f.stat("/dev/mapper/root", "253:0")
	f.stat(dataDir, "0:31")
	// mountinfo's source is not an enumeration of a btrfs filesystem's members.
	if got := f.system().Detect("/", dataDir); got.Root == Encrypted || got.Data == Encrypted {
		t.Fatalf("unenumerated btrfs membership claims encryption: %+v; want unknown unless every member was checked", got)
	}
}
