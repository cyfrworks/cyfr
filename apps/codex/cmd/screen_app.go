// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"sync"

	"github.com/cyfr/codex/internal/desktop"
)

// screenApp is the CYFR app as the box's screen, the browser of the
// screen's cyfr (runScreenShell), which serves it what desktop-serve
// serves the app on a desktop (desktop.Service, the screen's folder its
// This box) and says to it what that says, through say: the one way the
// shell talks to main, every message queued behind those before it
// (desktop.Writer.Queue), so nothing the shell does waits on main reading
// it. Nothing is said before ready (show): what the shell has to say by
// then (a lock, a missing keyboard, a watch not yet known to work) is
// said by the pages ready names once a CYFR opens. ending is the last
// message of a run: nothing is said after it.
//
// Every lock hides what the screen shows (hide, the service's Hide)
// before main is told, and a hide is never taken on main's word: main's
// thread can be stuck (a toolkit call that never returns), and with it
// what it would say. It is confirmed by the compositor's own list of the
// windows it shows (wayland.Windows): every window shown as the hide began
// has closed there within screenHideWithin. One not confirmed, or a list
// that cannot say, is carried out from outside: the app is ended (endApp),
// and its launcher starts it again, locked.
type screenApp struct {
	to *desktop.Writer

	// hiding marks what the screen shows as a hide begins and returns the
	// wait for it to be gone: nil once it is, why not otherwise.
	hiding func() (gone func() error)
	// endApp ends the app from outside, saying why (endScreenApp), at most
	// once (ended): this process ends with the app it ended, whose child
	// it is.
	endApp func(why error)
	ended  sync.Once
	// awaited counts the hides whose confirmation is awaited (finish).
	awaited sync.WaitGroup

	mu sync.Mutex
	// shown is whether ready was said, over whether ending was.
	shown, over bool
}

// say gives main m after every message given before it, nothing once
// ending was given.
func (a *screenApp) say(m desktop.Message) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.sayHeld(m)
}

// sayHeld is say, the caller holding a.mu.
func (a *screenApp) sayHeld(m desktop.Message) {
	if a.over {
		return
	}
	_ = a.to.Queue(m)
	a.over = m.Type == desktop.TypeEnding
}

// show says ready, the first message main hears, after which locks hide
// and are told.
func (a *screenApp) show(ready desktop.Message) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.sayHeld(ready)
	a.shown = true
}

// hide hides what is on the screen as a lock begins (desktop.Service.Hide):
// it marks what the compositor shows, then tells main through tell, and
// returns at once, waiting on nothing; the hide's confirmation is awaited
// apart, and a hide not confirmed ends the app. Before ready main shows
// nothing of the shell's yet, and after ending nothing more: either way
// nothing is marked or told.
func (a *screenApp) hide(tell func()) {
	a.mu.Lock()
	if !a.shown || a.over {
		a.mu.Unlock()
		return
	}
	// What is shown is marked before main is told, so a window main opens
	// for the lock page is none of it.
	gone := a.hiding()
	a.awaited.Add(1)
	go func() {
		defer a.awaited.Done()
		if err := gone(); err != nil {
			a.ended.Do(func() { a.endApp(err) })
		}
	}()
	a.mu.Unlock()
	tell()
}

// finish returns once every hide begun has been confirmed or carried out,
// so the process that returns from it, after the service's end, leaves
// none undone.
func (a *screenApp) finish() { a.awaited.Wait() }
