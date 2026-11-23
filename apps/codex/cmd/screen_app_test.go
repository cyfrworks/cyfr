// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"io"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/cyfr/codex/internal/desktop"
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

// The app's hide returns at once, whether or not main reads what it is
// told: a lock never waits on main.
func TestScreenApp_HideWaitsOnNothing(t *testing.T) {
	_, unread := io.Pipe()
	a := &screenApp{to: desktop.NewWriter(unread), home: desktop.Message{Type: desktop.TypeHome, Home: "http://localhost:4000", Account: "https://cyfr.run"}}
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

// lineSink is main's end of the pipe, read whole once written.
type lineSink struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (l *lineSink) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.b.Write(p)
}

// said is what the shell wrote, once it has written n lines, each as
// "type" or "type attempt".
func (l *lineSink) said(t *testing.T, n int) []string {
	t.Helper()
	var said []string
	for deadline := time.Now().Add(5 * time.Second); ; {
		l.mu.Lock()
		lines := strings.Split(strings.TrimSuffix(l.b.String(), "\n"), "\n")
		l.mu.Unlock()
		said = said[:0]
		for _, line := range lines {
			var m struct {
				Type    string `json:"type"`
				Attempt uint64 `json:"attempt"`
				Home    string `json:"home"`
			}
			if line == "" || json.Unmarshal([]byte(line), &m) != nil {
				continue
			}
			w := m.Type
			if m.Attempt > 0 {
				w += " " + strconv.FormatUint(m.Attempt, 10)
			}
			if m.Type == desktop.TypeLocked && m.Home != "" {
				w += " naming " + m.Home
			}
			said = append(said, w)
		}
		if len(said) >= n || time.Now().After(deadline) {
			return said
		}
		time.Sleep(10 * time.Millisecond) // sleep-ok: polls the writer's own goroutine
	}
}

// Nothing is said to main before ready, and ready is always first: locks
// before it (a keyboard that did not start, a watch not yet known to work)
// say nothing, since the page ready names is the lock page saying why,
// and ready comes with its proposal as attempt 1.
func TestScreenApp_ReadyIsTheFirstMessage(t *testing.T) {
	sink := &lineSink{}
	a := &screenApp{in: strings.NewReader(""), to: desktop.NewWriter(sink),
		home: desktop.Message{Type: desktop.TypeHome, Home: "http://localhost:4000", Account: "https://cyfr.run"}}
	a.hide()
	a.hide()
	if err := a.show(context.Background(), func(string) { a.hide() }); err != nil {
		t.Fatal(err)
	}
	want := []string{desktop.TypeReady, "home 1"}
	if said := sink.said(t, len(want)+1); strings.Join(said, ", ") != strings.Join(want, ", ") {
		t.Fatalf("the shell said %v, want %v", said, want)
	}
}

// What main says, and what the shell says back: ready and home as attempt
// 1; opened for the current attempt's home-ready alone, once; a lock's
// locked naming no CYFR, then home again as the next attempt; a stale
// home-ready or home-failed changes nothing, and leave is a lock that
// leaves no CYFR named; the current attempt's home-failed ends the shell;
// main's shutdown and the end of its pipe end it; a line that is not
// main's message ends it refused.
func TestScreenApp_WhatMainSays(t *testing.T) {
	const home = "http://localhost:4000"
	ready := func(n int) string {
		return `{"version":1,"type":"home-ready","home":"` + home + `","attempt":` + strconv.Itoa(n) + `}`
	}
	failed := func(n int) string {
		return `{"version":1,"type":"home-failed","home":"` + home + `","attempt":` + strconv.Itoa(n) + `}`
	}
	const lock, leave = `{"version":1,"type":"lock"}`, `{"version":1,"type":"leave"}`
	for name, c := range map[string]struct {
		lines   []string
		locks   []string
		said    []string
		refused bool
	}{
		"opened once": {lines: []string{ready(1), ready(1)}, said: []string{"opened"}},
		"a lock proposes again": {lines: []string{ready(1), lock, ready(1), failed(1), ready(2)}, locks: []string{"Locked."},
			said: []string{"opened", "locked", "home 2", "opened"}},
		"a stale home-ready": {lines: []string{lock, ready(1)}, locks: []string{"Locked."},
			said: []string{"locked", "home 2"}},
		"leave names no CYFR": {lines: []string{leave, ready(1), ready(2)}, locks: []string{"Locked."},
			said: []string{"locked", "home 2", "opened"}},
		"another CYFR's home-ready": {lines: []string{`{"version":1,"type":"home-ready","home":"https://other.example","attempt":1}`}},
		"the current home-failed": {lines: []string{lock, failed(2), lock}, locks: []string{"Locked."},
			said: []string{"locked", "home 2"}, refused: true},
		"shutdown":       {lines: []string{`{"version":1,"type":"shutdown"}`, lock}},
		"the pipe's end": {},
		"not a message":  {lines: []string{`{"version":1,"type":"unlock"}`}, refused: true},
	} {
		t.Run(name, func(t *testing.T) {
			sink := &lineSink{}
			a := &screenApp{in: strings.NewReader(strings.Join(c.lines, "\n")), to: desktop.NewWriter(sink),
				home: desktop.Message{Type: desktop.TypeHome, Home: home, Account: "https://cyfr.run"}}
			var locks []string
			// The shell's lock hides, every time, through the app (Restart).
			err := a.show(context.Background(), func(why string) { locks = append(locks, why); a.hide() })
			if (err != nil) != c.refused || strings.Join(locks, "|") != strings.Join(c.locks, "|") {
				t.Fatalf("show answered %v, locking %q", err, locks)
			}
			want := append([]string{desktop.TypeReady, "home 1"}, c.said...)
			if said := sink.said(t, len(want)); strings.Join(said, ", ") != strings.Join(want, ", ") {
				t.Fatalf("the shell said %v, want %v", said, want)
			}
		})
	}
}
