// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bufio"
	"bytes"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/cyfr/codex/internal/desktop"
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

// until skips what the shell says until a message of type want.
func (a *appSide) until(want string) map[string]any {
	a.t.Helper()
	for deadline := time.After(10 * time.Second); ; {
		select {
		case m := <-a.said:
			if m["type"] == want {
				return m
			}
		case <-deadline:
			a.t.Fatalf("the shell never said %s", want)
			return nil
		}
	}
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
	a := &screenApp{to: desktop.NewWriter(unread, nil), home: desktop.Message{Type: desktop.TypeHome, Home: "http://localhost:4000", Account: "https://cyfr.run"}}
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

// A message to main that cannot be written ends the screen's show, the
// app being gone, though main's pipe to the shell stays open.
func TestScreenApp_AWriteToMainThatFailsEndsTheShow(t *testing.T) {
	stay, held := io.Pipe()
	t.Cleanup(func() { held.Close() })
	read, write := io.Pipe()
	read.Close()
	a, err := newScreenApp(stay, write, desktop.Local{Shell: shell.Config{Address: "http://localhost:4000", Directory: "http://localhost:4000"}})
	if err != nil {
		t.Fatal(err)
	}
	shown := make(chan error, 1)
	go func() { shown <- a.show(func(string) {}) }()
	select {
	case err := <-shown:
		if err == nil || !strings.Contains(err.Error(), "could not be written") {
			t.Fatalf("show ended with %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("show went on after a write to main failed")
	}
}

// Nothing is said to main before ready, and ready is always first: locks
// before it (a keyboard that did not start, a watch not yet known to work)
// say nothing, since the page ready names is the lock page saying why,
// and ready comes with its proposal as attempt 1.
func TestScreenApp_ReadyIsTheFirstMessage(t *testing.T) {
	sink := &lineSink{}
	a := &screenApp{in: strings.NewReader(""), to: desktop.NewWriter(sink, nil),
		home: desktop.Message{Type: desktop.TypeHome, Home: "http://localhost:4000", Account: "https://cyfr.run"}}
	a.hide()
	a.hide()
	if err := a.show(func(string) { a.hide() }); err != nil {
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
// leaves no CYFR named, answered left once it ran; the current attempt's home-failed ends the shell;
// main's shutdown and the end of its pipe end it; a line that is not
// main's message ends it refused.
func TestScreenApp_WhatMainSays(t *testing.T) {
	const home = "http://localhost:4000"
	ready := func(n int) string {
		return `{"version":2,"type":"home-ready","home":"` + home + `","attempt":` + strconv.Itoa(n) + `}`
	}
	failed := func(n int) string {
		return `{"version":2,"type":"home-failed","home":"` + home + `","attempt":` + strconv.Itoa(n) + `}`
	}
	const lock, leave = `{"version":2,"type":"lock"}`, `{"version":2,"type":"leave","id":1}`
	for name, c := range map[string]struct {
		lines   []string
		locks   []string
		said    []string
		refused bool
	}{
		"opened once": {lines: []string{ready(1), ready(1)}, said: []string{"opened 1"}},
		"a lock proposes again": {lines: []string{ready(1), lock, ready(1), failed(1), ready(2)}, locks: []string{"Locked."},
			said: []string{"opened 1", "locked", "home 2", "opened 2"}},
		"a stale home-ready": {lines: []string{lock, ready(1)}, locks: []string{"Locked."},
			said: []string{"locked", "home 2"}},
		"leave names no CYFR": {lines: []string{leave, ready(1), ready(2)}, locks: []string{"Locked."},
			said: []string{"locked", "home 2", "left", "opened 2"}},
		"another CYFR's home-ready": {lines: []string{`{"version":2,"type":"home-ready","home":"https://other.example","attempt":1}`}},
		"the current home-failed": {lines: []string{lock, failed(2), lock}, locks: []string{"Locked."},
			said: []string{"locked", "home 2"}, refused: true},
		"shutdown":       {lines: []string{`{"version":2,"type":"shutdown"}`, lock}},
		"the pipe's end": {},
		"not a message":  {lines: []string{`{"version":2,"type":"unlock"}`}, refused: true},
	} {
		t.Run(name, func(t *testing.T) {
			sink := &lineSink{}
			a := &screenApp{in: strings.NewReader(strings.Join(c.lines, "\n")), to: desktop.NewWriter(sink, nil),
				home: desktop.Message{Type: desktop.TypeHome, Home: home, Account: "https://cyfr.run"}}
			var locks []string
			// The shell's lock hides, every time, through the app (Restart).
			err := a.show(func(why string) { locks = append(locks, why); a.hide() })
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

// The shell's end: its last lock says ending in place of locked and
// proposes nothing, and the shell says nothing after it, neither a second
// ending nor an opened for an answer still on its way; a shell ending
// before it showed anything says nothing at all.
func TestScreenApp_ItsLastLockSaysEndingAndNothingFollows(t *testing.T) {
	home := desktop.Message{Type: desktop.TypeHome, Home: "http://localhost:4000", Account: "https://cyfr.run"}
	in, answer := io.Pipe()
	sink := &lineSink{}
	a := &screenApp{in: in, to: desktop.NewWriter(sink, nil), home: home}
	shown := make(chan error, 1)
	go func() { shown <- a.show(func(string) { a.hide() }) }()
	sink.said(t, 2)
	a.end()
	a.hide()
	a.hide()
	if _, err := io.WriteString(answer, `{"version":2,"type":"home-ready","home":"http://localhost:4000","attempt":1}`+"\n"); err != nil {
		t.Fatal(err)
	}
	answer.Close()
	if err := <-shown; err != nil {
		t.Fatal(err)
	}
	want := []string{desktop.TypeReady, "home 1", desktop.TypeEnding}
	if said := sink.said(t, len(want)+1); strings.Join(said, ", ") != strings.Join(want, ", ") {
		t.Fatalf("the shell said %v, want %v", said, want)
	}

	early := &lineSink{}
	b := &screenApp{in: strings.NewReader(""), to: desktop.NewWriter(early, nil), home: home}
	b.end()
	b.hide()
	if err := b.show(func(string) { b.hide() }); err != nil {
		t.Fatal(err)
	}
	if said := early.said(t, 1); len(said) != 0 {
		t.Fatalf("a shell ending before it showed anything said %v", said)
	}
}

// ending is the last message of the shell's run: a leave the shell's last
// lock answers gets no left after it (tests/fixtures/desktop-process.json
// endings).
func TestScreenApp_NothingFollowsEnding(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "tests", "fixtures", "desktop-process.json"))
	if err != nil {
		t.Fatal(err)
	}
	var v struct {
		Endings []struct {
			Name     string            `json:"name"`
			ToCyfr   []json.RawMessage `json:"to_cyfr"`
			FromCyfr []struct {
				Type string `json:"type"`
			} `json:"from_cyfr"`
		} `json:"endings"`
	}
	if err := json.Unmarshal(raw, &v); err != nil || len(v.Endings) == 0 {
		t.Fatalf("no endings (%v)", err)
	}
	for _, c := range v.Endings {
		t.Run(c.Name, func(t *testing.T) {
			lines := make([]string, len(c.ToCyfr))
			for i, m := range c.ToCyfr {
				lines[i] = string(m)
			}
			sink := &lineSink{}
			a := &screenApp{in: strings.NewReader(strings.Join(lines, "\n")), to: desktop.NewWriter(sink, nil),
				home: desktop.Message{Type: desktop.TypeHome, Home: "http://localhost:4000", Account: "https://cyfr.run"}}
			// The lock main's message makes is the shell's last.
			if err := a.show(func(string) { a.end(); a.hide() }); err != nil {
				t.Fatal(err)
			}
			want := []string{desktop.TypeReady, "home 1"}
			for _, m := range c.FromCyfr {
				want = append(want, m.Type)
			}
			if said := sink.said(t, len(want)+1); strings.Join(said, ", ") != strings.Join(want, ", ") {
				t.Fatalf("the shell said %v, want %v", said, want)
			}
		})
	}
}
