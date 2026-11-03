// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package disk

import (
	"path/filepath"
	"syscall"
)

// Detect reports the running system's root filesystem and dataDir. dataDir's
// symlinks are resolved first, so a symlinked project directory is reported
// by the filesystem it points into.
func Detect(dataDir string) Report {
	if resolved, err := filepath.EvalSymlinks(dataDir); err == nil {
		dataDir = resolved
	}
	return System{}.Detect("/", dataDir)
}

// statDevice is System.Stat for the running system: st_rdev for a block
// device node, st_dev for anything else, decoded as the kernel encodes them.
func statDevice(path string) (major, minor uint32, err error) {
	var st syscall.Stat_t
	if err := syscall.Stat(path, &st); err != nil {
		return 0, 0, err
	}
	dev := uint64(st.Dev)
	if st.Mode&syscall.S_IFMT == syscall.S_IFBLK {
		dev = uint64(st.Rdev)
	}
	major = uint32((dev&0x00000000000fff00)>>8) | uint32((dev&0xfffff00000000000)>>32)
	minor = uint32(dev&0x00000000000000ff) | uint32((dev&0x00000ffffff00000)>>12)
	return major, minor, nil
}
