// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

// Command cyfr-spawn starts processes under uids of their own on behalf of
// an unprivileged client.
//
//	cyfr-spawn serve --pool <name>:<first>-<last> --home-root <dir> --client-user <user> -- <command> [args…]
//
// `serve` is the only subcommand an operator runs. It needs exactly the
// capabilities SETUID, SETGID and KILL and refuses to start with any other.
// `stage`, `relay` and `retire` are the helpers `serve` executes under the
// uid each one acts for; they read their instructions from a pipe on fd 3.
package main

import (
	"fmt"
	"os"

	"github.com/cyfr/spawn/internal/relay"
	"github.com/cyfr/spawn/internal/retire"
	"github.com/cyfr/spawn/internal/serve"
	"github.com/cyfr/spawn/internal/stage"
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
