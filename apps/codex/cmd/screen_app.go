// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"sync"

	"github.com/cyfr/codex/internal/account"
	"github.com/cyfr/codex/internal/desktop"
	"github.com/cyfr/codex/internal/shell"
)

// screenApp is the CYFR app as the screen's browser: its main process
// started `cyfr screen shell` in the screen's folder and talks to it
// over its stdin and stdout, in the messages of internal/desktop. The
// shell says ready with its own pages' address once the keyboard and the
// watches are up, then proposes home, the CYFR in the folder and the route
// to it, as attempt 1; main answers home-ready for it, and the shell says
// opened. A lock says locked, naming no CYFR, on which main hides the
// content and shows the shell's page again, and proposes home again as the
// next attempt: whatever main had of the last one, it takes the CYFR anew.
// Only the current attempt is answered: a home-ready for another, or one
// already answered, and a home-failed for another, change nothing. main's
// lock and leave, its shutdown and the end of its pipe are a lock of the
// shell; the last two end it as well. Every message goes through the
// writer's queue (desktop.Writer.Queue), so nothing the shell does waits
// on main reading it.
type screenApp struct {
	in   io.Reader
	to   *desktop.Writer
	home desktop.Message

	mu sync.Mutex
	// attempt is the current proposal's, and answered whether main's
	// home-ready for it was answered opened.
	attempt  uint64
	answered bool
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
	return &screenApp{in: in, to: desktop.NewWriter(out),
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

// hide hides what is on the screen and shows the lock page
// (shell.Config.Restart): it tells main locked, then proposes home again,
// and returns at once, waiting on nothing.
func (a *screenApp) hide() {
	a.mu.Lock()
	defer a.mu.Unlock()
	_ = a.to.Queue(desktop.Message{Type: desktop.TypeLocked})
	a.propose()
}

// show tells main the shell's pages and proposes the CYFR, then reads
// main's messages until main shuts the shell down or its pipe ends,
// locking the shell through lock (shell.Shell.Lock) where main asks it
// to: an error where main could not keep to the CYFR or said what is not
// a message.
func (a *screenApp) show(lock func(why string) (hid bool)) error {
	a.mu.Lock()
	_ = a.to.Queue(desktop.Message{Type: desktop.TypeReady, URL: shell.Origin + "/"})
	a.propose()
	a.mu.Unlock()
	lines := bufio.NewScanner(a.in)
	lines.Buffer(make([]byte, 0, 4096), desktop.MaxLine+1)
	for lines.Scan() {
		m, err := desktop.ReadFromMain(lines.Bytes())
		if err != nil {
			return err
		}
		switch m.Type {
		case desktop.TypeHomeReady:
			a.mu.Lock()
			if m.Home == a.home.Home && m.Attempt == a.attempt && !a.answered {
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
			// main waits for locked; a lock with nothing to hide says it
			// here, as no hide does.
			if !lock("Locked.") {
				a.hide()
			}
		case desktop.TypeShutdown:
			return nil
		}
	}
	return lines.Err()
}
