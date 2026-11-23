// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bufio"
	"bytes"
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
	show(ctx context.Context, lock func(why string)) error
	// hide hides what is on the screen and shows a fresh lock page
	// (shell.Config.Restart). It returns at once, waiting on nothing.
	hide()
	// end says the screen is ending: the next hide is its last, and
	// nothing shows after it.
	end()
}

// screenApp is the CYFR app as the screen's browser: its main process
// started `cyfr screen shell --app` in the screen's folder and talks to it
// over its stdin and stdout, in the messages of internal/desktop. The
// shell's first message, on every start, is ready with its own pages'
// address, once the watches have first worked or failed; then it proposes
// home, the CYFR in the folder and the route to it, as attempt 1; main
// answers home-ready for it, and the shell says opened. Nothing is said
// before ready: what the shell has to say by then (a lock, a missing
// keyboard, a watch not yet known to work) is said by the page ready
// names, which the shell draws locked and saying why. A lock after ready
// says locked, naming no CYFR, on which main hides the content and shows
// a fresh shell's page, and proposes home again as the next attempt:
// whatever main had of the last one, it takes the CYFR anew.
// Only the current attempt is answered: a home-ready for another, or one
// already answered, and a home-failed for another, change nothing. main's
// lock and leave, its shutdown and the end of its pipe are a lock of the
// shell; the last two end it as well. Every message goes through the
// writer's queue (desktop.Writer.Queue), so nothing the shell does waits
// on main reading it. The shell's last lock, at its end (end), says
// ending in place of locked and proposes nothing, and the shell says
// nothing after it: main closes at once and ends, opening no window for
// a shell that is going.
type screenApp struct {
	in   io.Reader
	to   *desktop.Writer
	home desktop.Message

	// gone is closed at the first message to main that could not be
	// written: the app has gone, and show ends.
	gone chan struct{}

	mu sync.Mutex
	// ready is whether ready was said; attempt is the current proposal's,
	// and answered whether main's home-ready for it was answered opened.
	ready    bool
	attempt  uint64
	answered bool
	// last is whether the shell is ending (end), and over whether it said
	// so: after that it says nothing.
	last, over bool
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
	gone := make(chan struct{})
	return &screenApp{in: in, to: desktop.NewWriter(out, func() { close(gone) }), gone: gone,
		home: desktop.Message{Type: desktop.TypeHome, Home: l.Shell.Address, Account: found.Origin, Proxy: l.Proxy, Resolver: l.Resolver}}, nil
}

// propose proposes home as the next attempt; the caller holds a.mu.
func (a *screenApp) propose() {
	a.attempt++
	a.answered = false
	home := a.home
	home.Attempt = a.attempt
	_ = a.to.Queue(home)
}

// hide hides what is on the screen and shows a fresh lock page
// (shell.Config.Restart): it tells main locked, then proposes home again,
// and returns at once, waiting on nothing. Before ready main shows nothing
// of the shell's yet, and the page ready names is the lock page. Once the
// shell is ending it tells main ending instead, once, and nothing more.
func (a *screenApp) hide() {
	a.mu.Lock()
	defer a.mu.Unlock()
	if !a.ready || a.over {
		return
	}
	if a.last {
		a.over = true
		_ = a.to.Queue(desktop.Message{Type: desktop.TypeEnding})
		return
	}
	_ = a.to.Queue(desktop.Message{Type: desktop.TypeLocked})
	a.propose()
}

// end makes the next hide the shell's last.
func (a *screenApp) end() {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.last = true
}

// show tells main the shell's pages and proposes the CYFR, then reads
// main's messages until main shuts the shell down, its pipe ends or a
// message to it could not be written, locking the shell through lock
// (shell.Shell.Lock) where main asks it to: an error where main could not
// keep to the CYFR, has gone, or said what is not a message.
func (a *screenApp) show(_ context.Context, lock func(why string)) error {
	a.mu.Lock()
	if a.last {
		// Ending before it showed anything: there is nothing to tell.
		a.mu.Unlock()
		return nil
	}
	_ = a.to.Queue(desktop.Message{Type: desktop.TypeReady, URL: shell.Origin + "/"})
	a.ready = true
	a.propose()
	a.mu.Unlock()
	lines, read, stop := make(chan []byte), make(chan error, 1), make(chan struct{})
	defer close(stop)
	go func() {
		s := bufio.NewScanner(a.in)
		s.Buffer(make([]byte, 0, 4096), desktop.MaxLine+1)
		for s.Scan() {
			select {
			case lines <- bytes.Clone(s.Bytes()):
			case <-stop:
				return
			}
		}
		read <- s.Err()
	}()
	for {
		var line []byte
		select {
		case <-a.gone:
			return errors.New("the CYFR app has gone: a message to it could not be written")
		case err := <-read:
			return err
		case line = <-lines:
		}
		m, err := desktop.ReadFromMain(line)
		if err != nil {
			return err
		}
		switch m.Type {
		case desktop.TypeHomeReady:
			a.mu.Lock()
			if m.Home == a.home.Home && m.Attempt == a.attempt && !a.answered && !a.over {
				a.answered = true
				_ = a.to.Queue(desktop.Message{Type: desktop.TypeOpened, Home: a.home.Home})
			}
			a.mu.Unlock()
		case desktop.TypeHomeFailed:
			a.mu.Lock()
			current := m.Home == a.home.Home && m.Attempt == a.attempt
			a.mu.Unlock()
			if current {
				return errors.New("the app could not keep to the CYFR here")
			}
		case desktop.TypeLock, desktop.TypeLeave:
			// main waits for locked, which the lock's hide says.
			lock("Locked.")
		case desktop.TypeShutdown:
			return nil
		}
	}
}
