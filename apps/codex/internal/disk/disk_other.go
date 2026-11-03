// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build !linux

package disk

import "errors"

// Detect reports Unknown for both paths: only Linux's block-device stack is
// read.
func Detect(dataDir string) Report {
	return Report{Root: Unknown, Data: Unknown}
}

func statDevice(string) (uint32, uint32, error) {
	return 0, 0, errors.ErrUnsupported
}
