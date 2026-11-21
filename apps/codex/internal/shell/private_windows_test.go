// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package shell

import (
	"os"
	"path/filepath"
	"testing"
	"unsafe"

	"golang.org/x/sys/windows"
)

// An existing device folder, which inherits whatever its profile folder
// allows, is made this account's and the system's alone before anything
// is read or kept there: owned by this account, under a protected access
// list naming no one else. (A folder another account owns is refused;
// making one needs a privilege no test holds.)
func TestDeviceDirKeepsAnExistingFolderPrivate(t *testing.T) {
	home := t.TempDir()
	t.Setenv("USERPROFILE", home)
	dir := filepath.Join(home, ".cyfr", "device")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	if got, err := DeviceDir(); err != nil || got != dir {
		t.Fatalf("DeviceDir = %q, %v", got, err)
	}
	sd, err := windows.GetNamedSecurityInfo(dir, windows.SE_FILE_OBJECT,
		windows.DACL_SECURITY_INFORMATION|windows.OWNER_SECURITY_INFORMATION)
	if err != nil {
		t.Fatal(err)
	}
	user, err := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil {
		t.Fatal(err)
	}
	mine, err := defaultOwner()
	if err != nil {
		t.Fatal(err)
	}
	if owner, _, err := sd.Owner(); err != nil || (!owner.Equals(user.User.Sid) && !owner.Equals(mine)) {
		t.Fatalf("the device folder's owner is %v, not this account (%v)", owner, err)
	}
	control, _, err := sd.Control()
	if err != nil || control&windows.SE_DACL_PROTECTED == 0 {
		t.Fatalf("the folder still inherits its access (%v)", err)
	}
	acl, _, err := sd.DACL()
	if err != nil || acl == nil {
		t.Fatalf("the folder has no access list (%v)", err)
	}
	system, _ := windows.CreateWellKnownSid(windows.WinLocalSystemSid)
	for i := range uint32(acl.AceCount) {
		var ace *windows.ACCESS_ALLOWED_ACE
		if err := windows.GetAce(acl, i, &ace); err != nil {
			t.Fatal(err)
		}
		sid := (*windows.SID)(unsafe.Pointer(&ace.SidStart))
		if !sid.Equals(user.User.Sid) && !sid.Equals(system) {
			t.Errorf("%s may reach into the device folder", sid)
		}
	}
}
