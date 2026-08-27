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
	defer stop()

	if err := cmd.Execute(ctx); err != nil {
		os.Exit(1)
	}
}
