// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package residue

import "golang.org/x/sys/unix"

// dirFlags open a path component for *at calls: O_PATH needs only search
// permission on the parent, so a uid reaches its entries under a home root
// it may not list.
const dirFlags = unix.O_PATH | unix.O_DIRECTORY | unix.O_NOFOLLOW | unix.O_CLOEXEC
