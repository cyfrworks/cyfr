// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

// Command cyfr-keeper starts processes under uids of their own on behalf of
// an unprivileged client.
//
//	cyfr-keeper serve --pool <name>:<first>-<last> --home-root <dir> --client-user <user> -- <command> [args…]
//
// `serve` is the only subcommand an operator runs. It needs exactly the
// capabilities SETUID, SETGID and KILL and refuses to start with any other.
// It bounds the memory of a spawn that asks for a bound only where its own
// cgroup is the root of a cgroup namespace mounted writable (Docker's
// `writable-cgroups=true` security option, which adds no capability), and
// refuses such a spawn anywhere else (package cgroup).
// `stage`, `relay` and `retire` are the helpers `serve` executes under the
// uid each one acts for; they read their instructions from a pipe on fd 3.
package main

import (
	"fmt"
	"os"

	"github.com/cyfr/keeper/internal/relay"
	"github.com/cyfr/keeper/internal/retire"
	"github.com/cyfr/keeper/internal/serve"
	"github.com/cyfr/keeper/internal/stage"
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
