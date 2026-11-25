// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

// Command cyfr-guest is the guest agent of a person's machine (package vm):
// the first process of the guest's kernel, run from the image's programs,
// which are the guest's read-only root.
//
//	cyfr-guest           as the guest's first process: its mounts, the
//	                     guard, the keeper's group, the keeper, and the
//	                     machine's end
//	cyfr-guest guard     the guard's start: NET_ADMIN alone, then the
//	                     image's cyfr-guard
//	cyfr-guest keeper    the keeper's start, in the group and namespaces the
//	                     first process gave it: execs `cyfr-locus serve`
//	cyfr-guest relay     the guest keeper's one role, run by that keeper:
//	                     carries its channel and its spawns' attach
//	                     connections to the host over vsock
//
// The spaces of the guest are the keeper's own, made by the same
// `cyfr-locus serve` as in the Locus container: the agent adds nothing to
// how a space is made, and holds no capability once the keeper runs.
package main

import (
	"fmt"
	"os"
)

func main() {
	if os.Getpid() == 1 {
		os.Exit(initMain())
	}
	if len(os.Args) == 2 {
		switch os.Args[1] {
		case "guard":
			os.Exit(guardMain())
		case "keeper":
			os.Exit(keeperMain())
		case "relay":
			os.Exit(relayMain())
		}
	}
	fmt.Fprintln(os.Stderr, "usage: cyfr-guest (as the guest's first process) | cyfr-guest guard | cyfr-guest keeper | cyfr-guest relay")
	os.Exit(64)
}

func logf(format string, a ...any) {
	fmt.Fprintf(os.Stderr, "cyfr-guest: "+format+"\n", a...)
}
