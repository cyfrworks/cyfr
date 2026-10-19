// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package main

import (
	"context"
	"os"
	"os/signal"
	"syscall"

	"github.com/cyfr/codex/cmd"
)

func main() {
	// Ctrl-C / SIGTERM cancel the context every in-flight request carries,
	// so commands unwind through their defers and cleanup hooks instead of
	// the process dying mid-write.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)

	// The one place a command's failure ends the process: cmd.Run answers
	// its status (cmd.ExitStatus), and the context's signal handling is
	// released before the exit.
	status := cmd.Run(ctx)
	stop()
	os.Exit(status)
}
