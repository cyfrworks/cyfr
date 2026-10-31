// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build windows

package cmd

import (
	"errors"
	"os"
)

// No root entry runs on Windows: automatic preparation is Linux's alone.
func ownedByRoot(os.FileInfo) bool { return false }

func ownedBy(os.FileInfo, int) bool { return false }

// makeFIFO: no root entry runs on Windows.
func makeFIFO(string) error { return errors.New("no FIFO on Windows") }

const (
	openNoFollow = 0
	openNonBlock = 0
)
