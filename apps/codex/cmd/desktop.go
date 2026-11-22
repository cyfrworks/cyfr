// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"time"

	"github.com/spf13/cobra"

	"github.com/cyfr/codex/internal/desktop"
	"github.com/cyfr/codex/internal/holder"
	"github.com/cyfr/codex/internal/shell"
)

func init() {
	desktopServeCmd.Flags().BoolVar(&desktopAccountRoad, "account-road", false,
		"the app signs in with the account's passkey too")
	rootCmd.AddCommand(desktopServeCmd)
}

// desktopAccountRoad is whether the app offers the passkey road, which
// main decides (by the platform) and says as it starts cyfr.
var desktopAccountRoad bool

// desktopServeCmd is the cyfr the CYFR app's main process starts and
// talks to over its stdin and stdout (internal/desktop): no person runs
// it, and nothing but those messages is written to its stdout.
var desktopServeCmd = &cobra.Command{
	Use:    "desktop-serve",
	Short:  "Serve the CYFR app's pages to its main process",
	Hidden: true,
	Args:   cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		return runDesktopServe(cmd.Context(), os.Stdin, os.Stdout, desktopAccountRoad)
	},
}

// runDesktopServe binds the shell's listener for this process alone, says
// ready to main with the chooser's address, then serves until main sends
// shutdown, its pipe ends, or it sends a line that is not its message.
// Every end locks the device first, saying nothing to main
// (desktop.Service.End): an end signs nobody out.
func runDesktopServe(ctx context.Context, in io.Reader, out io.Writer, accountRoad bool) error {
	_ = holder.HardenProcess()
	dir, err := shell.DeviceDir()
	if err != nil {
		return fmt.Errorf("this account's device folder cannot be made (%v)", err)
	}
	ln, err := shell.ListenLoopback()
	if err != nil {
		return fmt.Errorf("another program holds %s: close the app using port 7340, then open CYFR again (%v)", shell.Listen, err)
	}
	to := desktop.NewWriter(out)
	host, _ := os.Hostname()
	svc := &desktop.Service{
		AccountRoad: accountRoad,
		Token:       desktop.NewToken(),
		Clients:     shell.ClientFile(filepath.Join(dir, "client.json")),
		Record:      filepath.Join(dir, "holder.json"),
		Client:      &http.Client{},
		DisplayName: host,
		Send:        to.Send,
	}
	hs := &http.Server{Handler: svc, ReadHeaderTimeout: 10 * time.Second}
	served := make(chan error, 1)
	go func() { served <- hs.Serve(ln) }()
	defer func() {
		sctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = hs.Shutdown(sctx)
	}()
	if err := to.Send(desktop.Message{Type: desktop.TypeReady, URL: svc.ReadyURL()}); err != nil {
		return err
	}
	ran := make(chan error, 1)
	go func() { ran <- svc.Run(in) }()
	select {
	case err := <-ran:
		return err
	case err := <-served:
		svc.End()
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return err
	case <-ctx.Done():
		svc.End()
		return nil
	}
}
