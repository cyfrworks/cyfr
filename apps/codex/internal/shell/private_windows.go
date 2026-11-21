// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package shell

import (
	"errors"
	"unsafe"

	"golang.org/x/sys/windows"
)

// privateFolder holds dir to this account alone: a folder this account
// owns, since its owner can always change who may reach it, whose access
// list becomes full control for this account and for the system,
// inherited by what it holds, with nothing inherited from the folders
// above it. A folder another account owns is refused.
func privateFolder(dir string) error {
	user, err := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil {
		return err
	}
	sd, err := windows.GetNamedSecurityInfo(dir, windows.SE_FILE_OBJECT, windows.OWNER_SECURITY_INFORMATION)
	if err != nil {
		return err
	}
	owner, _, err := sd.Owner()
	if err != nil {
		return err
	}
	mine, err := defaultOwner()
	if err != nil {
		return err
	}
	// Another user's folder is refused. The process's own default owner is
	// accepted too: an elevated administrator's new objects belong to the
	// Administrators group where Windows is set so, as on Windows Server,
	// and an administrator of the machine can take ownership of any folder
	// whatever this code does, as root can on Unix, so accepting that group
	// gives no one a power an administrator lacks.
	if !owner.Equals(user.User.Sid) && !owner.Equals(mine) {
		return errors.New("another account owns it")
	}
	attrs, err := windows.GetFileAttributes(windows.StringToUTF16Ptr(dir))
	if err != nil {
		return err
	}
	if attrs&windows.FILE_ATTRIBUTE_REPARSE_POINT != 0 {
		return errors.New("it is a link, not a folder")
	}
	system, err := windows.CreateWellKnownSid(windows.WinLocalSystemSid)
	if err != nil {
		return err
	}
	var entries []windows.EXPLICIT_ACCESS
	for _, sid := range []*windows.SID{user.User.Sid, system} {
		entries = append(entries, windows.EXPLICIT_ACCESS{
			AccessPermissions: windows.GENERIC_ALL,
			AccessMode:        windows.SET_ACCESS,
			Inheritance:       windows.SUB_CONTAINERS_AND_OBJECTS_INHERIT,
			Trustee: windows.TRUSTEE{TrusteeForm: windows.TRUSTEE_IS_SID, TrusteeType: windows.TRUSTEE_IS_UNKNOWN,
				TrusteeValue: windows.TrusteeValueFromSID(sid)},
		})
	}
	acl, err := windows.ACLFromEntries(entries, nil)
	if err != nil {
		return err
	}
	return windows.SetNamedSecurityInfo(dir, windows.SE_FILE_OBJECT,
		windows.DACL_SECURITY_INFORMATION|windows.PROTECTED_DACL_SECURITY_INFORMATION, nil, nil, acl, nil)
}

// defaultOwner is the owner this process gives what it makes: this account,
// or the Administrators group for an elevated administrator where Windows
// is set so, as on Windows Server.
func defaultOwner() (*windows.SID, error) {
	token := windows.GetCurrentProcessToken()
	var n uint32
	_ = windows.GetTokenInformation(token, windows.TokenOwner, nil, 0, &n)
	if n == 0 {
		return nil, errors.New("this process's default owner cannot be read")
	}
	buf := make([]byte, n)
	if err := windows.GetTokenInformation(token, windows.TokenOwner, &buf[0], n, &n); err != nil {
		return nil, err
	}
	return (*struct{ Owner *windows.SID })(unsafe.Pointer(&buf[0])).Owner.Copy()
}
