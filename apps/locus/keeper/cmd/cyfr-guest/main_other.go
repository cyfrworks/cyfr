// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build !linux

// Command cyfr-guest runs only as a Linux guest's first process; see main.go.
package main

import (
	"fmt"
	"os"
)

func main() {
	fmt.Fprintln(os.Stderr, "cyfr-guest runs on Linux only")
	os.Exit(69)
}
