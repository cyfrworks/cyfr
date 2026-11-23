// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"sync"

	"github.com/cyfr/codex/internal/account"
	"github.com/cyfr/codex/internal/desktop"
	"github.com/cyfr/codex/internal/shell"
)

// screenBrowser is what shows the screen shell's pages: Chrome, which the
// shell starts, or the CYFR app, which started the shell.
type screenBrowser interface {
	// show shows the shell's pages until ctx ends or the browser has
	// ended for good, locking the shell through lock (shell.Shell.Lock)
	// where the browser asks it to or ended: an error where it could not
	// show them.
	show(ctx context.Context, lock func(why string) (closed bool)) error
	// hide hides what is on the screen and shows the lock page
	// (shell.Config.Restart). It returns at once, waiting on nothing.
	hide()
}

// screenApp is the CYFR app as the screen's browser: its main process
// started `cyfr screen shell --app` in the screen's folder and talks to it
// over its stdin and stdout, in the messages of internal/desktop. The
// shell says ready with its own pages' address once the keyboard and the
// watches are up, then home with the CYFR in the folder and the route to
// it; main answers home-ready, and the shell says opened. A lock says
// locked, on which main hides the content and shows the shell's page again.
// main's lock, shutdown and the end of its pipe are a lock of the shell;
// the last two end it as well.
type screenApp struct {
	in   io.Reader
	to   *desktop.Writer
	home desktop.Message

	mu    sync.Mutex
	queue []desktop.Message
	wake  chan struct{}
}

// newScreenApp is the app as the browser of the CYFR l, set up in the
// screen's folder, reading main's messages from in and writing its own to
// out, which nothing else writes to.
func newScreenApp(in io.Reader, out io.Writer, l desktop.Local) (*screenApp, error) {
	found, ok := account.ServiceOf(l.Shell.Address, l.Shell.Directory)
	if !ok {
		return nil, fmt.Errorf("The CYFR here names %s as its account service. The app takes an https address, "+
			"or a plain http one only at a CYFR's own address on this computer", l.Shell.Directory)
	}
	a := &screenApp{in: in, to: desktop.NewWriter(out), wake: make(chan struct{}, 1),
		home: desktop.Message{Home: l.Shell.Address, Account: found.Origin, Proxy: l.Proxy, Resolver: l.Resolver}}
	go a.write()
	return a, nil
}

// send queues m for main, in order: a write that main is slow to take
// holds no lock up.
func (a *screenApp) send(m desktop.Message) {
	a.mu.Lock()
	a.queue = append(a.queue, m)
	a.mu.Unlock()
	select {
	case a.wake <- struct{}{}:
	default:
	}
}

// write writes what send queued, until a write fails: main has gone, and
// the end of its pipe ends the shell.
func (a *screenApp) write() {
	for range a.wake {
		a.mu.Lock()
		queued := a.queue
		a.queue = nil
		a.mu.Unlock()
		for _, m := range queued {
			if a.to.Send(m) != nil {
				return
			}
		}
	}
}

func (a *screenApp) hide() {
	m := a.home
	m.Type = desktop.TypeLocked
	a.send(m)
}

func (a *screenApp) show(_ context.Context, lock func(string) bool) error {
	a.send(desktop.Message{Type: desktop.TypeReady, URL: shell.Origin + "/"})
	home := a.home
	home.Type, home.Attempt = desktop.TypeHome, 1
	a.send(home)
	lines := bufio.NewScanner(a.in)
	lines.Buffer(make([]byte, 0, 4096), desktop.MaxLine+1)
	for lines.Scan() {
		m, err := desktop.ReadFromMain(lines.Bytes())
		if err != nil {
			return err
		}
		switch m.Type {
		case desktop.TypeHomeReady:
			if m.Home == a.home.Home && m.Attempt == 1 {
				a.send(desktop.Message{Type: desktop.TypeOpened, Home: a.home.Home})
			}
		case desktop.TypeHomeFailed:
			return errors.New("the app could not keep to the CYFR here")
		case desktop.TypeLock, desktop.TypeLeave:
			// main waits for locked; a shell locked already says it here,
			// as no hide does.
			if !lock("Locked.") {
				a.hide()
			}
		case desktop.TypeShutdown:
			return nil
		}
	}
	return lines.Err()
}
