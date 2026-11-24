// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
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
	rootCmd.AddCommand(desktopServeCmd)
}

// desktopServeCmd is the cyfr the CYFR app's main process starts and
// talks to over its stdin and stdout (internal/desktop): no person runs
// it, and nothing but those messages is written to its stdout.
var desktopServeCmd = &cobra.Command{
	Use:    "desktop-serve",
	Short:  "Serve the CYFR app's pages to its main process",
	Hidden: true,
	Args:   cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		return runDesktopServe(cmd.Context(), shell.ListenLoopback, os.Stdin, os.Stdout)
	},
}

// runDesktopServe takes the shell's listener through listen, for this
// process alone, says ready to main with the chooser's address, then
// serves until main sends
// shutdown, its pipe ends, a message to it cannot be written, or it sends
// a line that is not its message.
// Every end locks the device first, saying nothing to main
// (desktop.Service.End): an end signs nobody out.
func runDesktopServe(ctx context.Context, listen func() (net.Listener, error), in io.Reader, out io.Writer) error {
	_ = holder.HardenProcess()
	dir, err := shell.DeviceDir()
	if err != nil {
		return fmt.Errorf("this account's device folder cannot be made (%v)", err)
	}
	ln, err := listen()
	if err != nil {
		return fmt.Errorf("another program holds %s: close the app using port 7340, then open CYFR again (%v)", shell.Listen, err)
	}
	// A write to main that fails ends the service: the app is gone.
	gone := make(chan struct{})
	to := desktop.NewWriter(out, func() { close(gone) })
	svc := newDesktopService(ctx, dir, func(m desktop.Message) { _ = to.Queue(m) })
	hs := &http.Server{Handler: svc, ReadHeaderTimeout: 10 * time.Second}
	served := make(chan error, 1)
	go func() { served <- hs.Serve(ln) }()
	defer func() {
		sctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = hs.Shutdown(sctx)
		// Shutdown closes only a listener Serve has begun with: one whose
		// goroutine had not yet run is closed here, by the listener's taker,
		// so nothing is served on the port once this returns.
		_ = ln.Close()
	}()
	if err := to.Queue(desktop.Message{Type: desktop.TypeReady, URL: svc.ReadyURL(), Rail: svc.RailURL()}); err != nil {
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
	case <-gone:
		svc.End()
		return errors.New("the CYFR app has gone: a message to it could not be written")
	case <-ctx.Done():
		svc.End()
		return nil
	}
}

// newDesktopService is what desktop-serve serves over this user's device
// folder until ctx ends, saying to main through tell, which waits on nothing.
func newDesktopService(ctx context.Context, device string, tell func(desktop.Message)) *desktop.Service {
	host, _ := os.Hostname()
	home, _ := os.UserHomeDir()
	return &desktop.Service{
		Token:       desktop.NewToken(),
		ReadToken:   desktop.NewToken(),
		Homes:       shell.Homes(filepath.Join(device, "homes.json")),
		Record:      filepath.Join(device, "holder.json"),
		Client:      &http.Client{},
		DisplayName: host,
		Tell:        tell,
		Folder:      filepath.Join(home, "cyfr"),
		Docker: func(ctx context.Context) desktop.DockerAnswer {
			return dockerCheck(ctx, shell.NewWork(ctx))
		},
		// A setup runs until cyfr ends, whatever the chooser does.
		Setup: func(_ context.Context, folder string, step func(string)) error {
			return setUpHere(ctx, shell.NewWork(ctx), folder, step)
		},
		Local: func(project string) (desktop.Local, error) {
			// The reading holds work from here: its caller once it is
			// returned, and this function until then, a panic too.
			work := shell.NewWork(ctx)
			returned := false
			defer func() {
				if !returned {
					work.End()
				}
			}()
			l, err := readLocal(work, project, "the CYFR app")
			if err != nil {
				return desktop.Local{}, engineFailure(err)
			}
			returned = true
			return l, nil
		},
	}
}
