// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build !unix

package cmd

import "os"

// killSelf ends this process as the platform ends one outright
// (TerminateProcess on Windows), as a cyfr that dies where it stands.
func killSelf() {
	if p, err := os.FindProcess(os.Getpid()); err == nil {
		p.Kill()
	}
}
