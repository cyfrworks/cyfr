// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package main

import (
	"context"
	"errors"
	"os"
	"os/signal"
	"syscall"

	"github.com/cyfr/codex/cmd"
	"github.com/cyfr/codex/internal/prompt"
)

func main() {
	// Ctrl-C / SIGTERM cancel the context every in-flight request carries,
	// so commands unwind through their defers and cleanup hooks instead of
	// the process dying mid-write.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	if err := cmd.Execute(ctx); err != nil {
		// A prompt abort is the user's own Ctrl-C: report it in the exit
		// code the shell convention reserves for it (128+SIGINT), with no
		// error output — Execute already skipped printing it.
		if errors.Is(err, prompt.ErrAborted) {
			os.Exit(130)
		}
		os.Exit(1)
	}
}
