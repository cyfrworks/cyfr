// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build !linux

package residue

import "golang.org/x/sys/unix"

// dirFlags open a path component for *at calls. Without O_PATH each
// component must be readable; cyfr-spawn itself runs on Linux only.
const dirFlags = unix.O_RDONLY | unix.O_DIRECTORY | unix.O_NOFOLLOW | unix.O_CLOEXEC
