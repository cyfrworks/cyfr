// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

// Command cyfr-locus starts processes under uids and in spaces of their own
// (a user, network and IPC namespace each) on behalf of an unprivileged
// client.
//
//	cyfr-locus serve --pool <name>:<first>-<last>:<relay|routed> --home-root <dir> [--kept-homes <dir>:<first>-<last>] [--guard <socket>] --client-user <user> -- <command> [args…]
//	cyfr-locus guard-control <socket> <range>
//	cyfr-locus guest-check [--kernel-reporting] [-- <command> [args…]]
//
// `serve` is the only subcommand an operator runs; `guard-control` is the
// one an island's egress guard runs once its rules are in (package guard). It needs exactly the
// capabilities SETUID, SETGID and KILL and refuses to start with any other,
// as does `guest-check`, which boots one person's machine as the keeper
// does, has the machine's keeper make and end one space, and reports
// (package vm).
// Every spawn requires a memory bound. The keeper enforces it only where
// its cgroup is the root of a cgroup namespace mounted writable (Docker's
// `writable-cgroups=true` security option, which adds no capability), and
// refuses spawns anywhere else (package cgroup).
// `stage`, `relay`, `retire` and `home` are helpers that read their
// instructions from a pipe on fd 3. A stage starts in its space with the
// keeper's ids until its namespace is mapped; retirement helpers start as
// their pooled uid, home helpers as their kept home's uid, and relays start
// as the client user.
package main

import (
	"fmt"
	"os"

	"github.com/cyfr/locus/keeper/guard"
	"github.com/cyfr/locus/keeper/internal/home"
	"github.com/cyfr/locus/keeper/internal/relay"
	"github.com/cyfr/locus/keeper/internal/retire"
	"github.com/cyfr/locus/keeper/internal/serve"
	"github.com/cyfr/locus/keeper/internal/stage"
	"github.com/cyfr/locus/keeper/internal/vm"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: "+serve.Usage)
		os.Exit(serve.ExitUsage)
	}
	switch os.Args[1] {
	case "serve":
		os.Exit(serve.Main(os.Args[2:]))
	case "stage":
		os.Exit(stage.Main())
	case "relay":
		os.Exit(relay.Main())
	case "retire":
		os.Exit(retire.Main())
	case "home":
		os.Exit(home.HelperMain())
	case "guard-control":
		os.Exit(guard.Main(os.Args[2:]))
	case "guest-check":
		os.Exit(vm.CheckMain(os.Args[2:]))
	default:
		fmt.Fprintln(os.Stderr, "usage: "+serve.Usage)
		os.Exit(serve.ExitUsage)
	}
}
