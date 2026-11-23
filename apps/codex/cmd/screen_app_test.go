// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"strings"
	"testing"
	"time"

	"github.com/cyfr/codex/internal/desktop"
	"github.com/cyfr/codex/internal/idle/idletest"
	"github.com/cyfr/codex/internal/shell"
)

// appSide is the CYFR app's main process as the screen shell's browser
// sees it: what the shell says, line by line, and a pipe to answer on.
type appSide struct {
	t     *testing.T
	said  chan map[string]any
	reply *io.PipeWriter
}

func newAppSide(t *testing.T) (*appSide, io.Reader, io.Writer) {
	inR, inW := io.Pipe()
	outR, outW := io.Pipe()
	a := &appSide{t: t, said: make(chan map[string]any, 16), reply: inW}
	go func() {
		lines := bufio.NewScanner(outR)
		for lines.Scan() {
			var m map[string]any
			if json.Unmarshal(lines.Bytes(), &m) != nil {
				m = map[string]any{"type": "not a message: " + lines.Text()}
			}
			a.said <- m
		}
	}()
	t.Cleanup(func() { inW.Close(); outR.Close() })
	return a, inR, outW
}

// next is the shell's next message, which must be of type want.
func (a *appSide) next(want string) map[string]any {
	a.t.Helper()
	select {
	case m := <-a.said:
		if m["type"] != want {
			a.t.Fatalf("the shell said %v, want %s", m, want)
		}
		return m
	case <-time.After(10 * time.Second):
		a.t.Fatalf("the shell never said %s", want)
	}
	return nil
}

func (a *appSide) send(line string) {
	a.t.Helper()
	if _, err := io.WriteString(a.reply, line+"\n"); err != nil {
		a.t.Fatal(err)
	}
}

// The screen shell with the app as its browser: once the keyboard and the
// watches are up it says ready with its own pages' address, then home with
// the CYFR in its folder; main's home-ready is answered opened; a lock says
// locked, naming that CYFR; the end of main's pipe ends the shell.
func TestScreenShell_TheAppIsItsBrowser(t *testing.T) {
	screenProject(t)
	compositor := screenCompositor(t, idletest.Options{})
	screenPrograms(t, quietScreen())
	app, in, out := newAppSide(t)
	listen, _ := ownListener()
	ended := make(chan error, 1)
	go func() { ended <- runScreenShell(context.Background(), listen, appBrowser(in, out)) }()

	if ready := app.next("ready"); ready["url"] != shell.Origin+"/" {
		t.Fatalf("ready named %v", ready["url"])
	}
	home := app.next("home")
	if home["home"] == "" || home["account"] == "" || home["attempt"] != float64(1) {
		t.Fatalf("home was %v", home)
	}
	app.send(`{"version":1,"type":"home-ready","home":"` + home["home"].(string) + `","attempt":1}`)
	if opened := app.next("opened"); opened["home"] != home["home"] {
		t.Fatalf("opened named %v, home %v", opened["home"], home["home"])
	}
	// The idle watch lost: what is on the screen gives way to the page
	// that says why.
	compositor.Stop()
	if locked := app.next("locked"); locked["home"] != home["home"] || locked["account"] != home["account"] {
		t.Fatalf("locked was %v, home %v", locked, home)
	}
	app.reply.Close()
	select {
	case err := <-ended:
		if err != nil {
			t.Fatalf("the end of main's pipe ended the shell with %v", err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("the end of main's pipe did not end the shell")
	}
}

// The app's hide returns at once, whether or not main reads what it is
// told: a lock never waits on main.
func TestScreenApp_HideWaitsOnNothing(t *testing.T) {
	_, unread := io.Pipe()
	a := &screenApp{to: desktop.NewWriter(unread), wake: make(chan struct{}, 1), home: desktop.Message{Home: "http://localhost:4000", Account: "https://cyfr.run"}}
	go a.write()
	hidden := make(chan struct{})
	go func() {
		for range 3 {
			a.hide()
		}
		close(hidden)
	}()
	select {
	case <-hidden:
	case <-time.After(2 * time.Second):
		t.Fatal("hide waited for main to read")
	}
}

// main's lock and leave lock the shell, its shutdown and the end of its
// pipe end it, and a line that is not main's message ends it refused.
func TestScreenApp_WhatMainSays(t *testing.T) {
	for name, c := range map[string]struct {
		lines   []string
		locks   []string
		refused bool
	}{
		"lock":           {lines: []string{`{"version":1,"type":"lock"}`}, locks: []string{"Locked."}},
		"leave":          {lines: []string{`{"version":1,"type":"leave"}`}, locks: []string{"Locked."}},
		"shutdown":       {lines: []string{`{"version":1,"type":"shutdown"}`, `{"version":1,"type":"lock"}`}},
		"the pipe's end": {},
		"not a message":  {lines: []string{`{"version":1,"type":"unlock"}`}, refused: true},
	} {
		t.Run(name, func(t *testing.T) {
			a := &screenApp{in: strings.NewReader(strings.Join(c.lines, "\n")), to: desktop.NewWriter(io.Discard),
				wake: make(chan struct{}, 1)}
			var locks []string
			err := a.show(context.Background(), func(why string) bool { locks = append(locks, why); return false })
			if (err != nil) != c.refused || strings.Join(locks, "|") != strings.Join(c.locks, "|") {
				t.Fatalf("show answered %v, locking %q", err, locks)
			}
			// After ready and home, a lock that closed nothing says locked
			// all the same, as no hide did.
			var said []string
			for _, m := range a.queue {
				said = append(said, m.Type)
			}
			want := []string{desktop.TypeReady, desktop.TypeHome}
			for range c.locks {
				want = append(want, desktop.TypeLocked)
			}
			if strings.Join(said, " ") != strings.Join(want, " ") {
				t.Fatalf("the shell said %v, want %v", said, want)
			}
		})
	}
}
