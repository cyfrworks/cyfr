// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build !windows

package cmd

import (
	"os"

	"golang.org/x/sys/unix"
)

// echoOff turns off the echo of standard input's terminal, keeping its
// line editing, so a PIN or passphrase typed there is not shown; the
// answer restores it. Standard input that is no terminal is left as it is.
func echoOff() func() {
	fd := int(os.Stdin.Fd())
	before, err := unix.IoctlGetTermios(fd, getTermios)
	if err != nil {
		return func() {}
	}
	quiet := *before
	quiet.Lflag &^= unix.ECHO
	if unix.IoctlSetTermios(fd, setTermios, &quiet) != nil {
		return func() {}
	}
	return func() { _ = unix.IoctlSetTermios(fd, setTermios, before) }
}
