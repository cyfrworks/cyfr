// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

// Command cyfr-locus starts a process for each role whose key it is given,
// and processes under uids on each one's behalf, every one in a space of
// its own (a user, pid, IPC, mount, cgroup and network namespace each).
//
//	cyfr-locus serve --role <name>:<uid>:<port>:<pool>[:private][:kept] [--role …] --pool <name>:<first>-<last>:<relay|routed> [--pool …] --home-root <dir> [--kept-homes <dir>:<first>-<last>] --guard <socket> -- <command> [args…]
//	cyfr-locus guard-control <socket> <range>
//
// `serve` is the only subcommand an operator runs; `guard-control` is the
// one an island's egress guard runs once its rules are in (package guard). It needs exactly the
// capabilities SETUID, SETGID and KILL and refuses to start with any other.
// Every role and spawn is held in a cgroup group of its own, each role's
// to its LOCUS_<NAME>_MEMORY_LIMIT and _CPU_LIMIT, each spawn's to its
// memory bound. The keeper makes them only where its cgroup is the root of
// a cgroup namespace mounted writable (Docker's `writable-cgroups=true`
// security option, which adds no capability), and refuses its boot
// anywhere else (package cgroup).
// `stage`, `relay`, `retire` and `home` are helpers that read their
// instructions from a pipe on fd 3. A stage starts in its space with the
// keeper's ids until its namespace is mapped; retirement helpers start as
// their pooled uid, home helpers as their kept home's uid, and relays start
// as their spawn's role's uid, in that role's group.
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
	default:
		fmt.Fprintln(os.Stderr, "usage: "+serve.Usage)
		os.Exit(serve.ExitUsage)
	}
}
