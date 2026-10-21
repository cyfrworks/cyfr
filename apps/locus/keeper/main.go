// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

// Command cyfr-locus starts processes under uids of their own on behalf of
// an unprivileged client.
//
//	cyfr-locus serve --pool <name>:<first>-<last>[:netns] --home-root <dir> --client-user <user> -- <command> [args…]
//
// `serve` is the only subcommand an operator runs. It needs exactly the
// capabilities SETUID, SETGID and KILL and refuses to start with any other.
// Every spawn requires a memory bound. The keeper enforces it only where
// its cgroup is the root of a cgroup namespace mounted writable (Docker's
// `writable-cgroups=true` security option, which adds no capability), and
// refuses spawns anywhere else (package cgroup).
// `stage`, `relay` and `retire` are helpers that read their instructions
// from a pipe on fd 3. An isolated stage starts with the keeper's ids until
// its namespace is mapped; other stages and retirement helpers start as
// their pooled uid, and relays start as the client user.
package main

import (
	"fmt"
	"os"

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
	default:
		fmt.Fprintln(os.Stderr, "usage: "+serve.Usage)
		os.Exit(serve.ExitUsage)
	}
}
