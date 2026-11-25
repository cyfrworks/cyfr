// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/exec"
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

// confirmed stands in for the compositor's word on a hide: every one is
// confirmed.
func confirmed() func() error { return func() error { return nil } }

// readyMessage is the screen's ready, as runScreenShell says it.
var readyMessage = desktop.Message{Type: desktop.TypeReady, URL: shell.Origin + "/bootstrap/#token=t", Rail: shell.Origin + "/rail/#read=r"}

// shown is a screenApp that said ready, its messages in sink, its hides
// confirmed.
func shown(sink *lineSink) *screenApp {
	a := &screenApp{to: desktop.NewWriter(sink, nil), hiding: confirmed}
	a.show(readyMessage)
	return a
}

// told is the lock's message the service gives a hide to tell.
func told(a *screenApp) func() { return func() { a.say(desktop.Message{Type: desktop.TypeLocked}) } }

// The app's hide returns at once, whether or not main reads what it is
// told: a lock never waits on main.
func TestScreenApp_HideWaitsOnNothing(t *testing.T) {
	_, unread := io.Pipe()
	a := &screenApp{to: desktop.NewWriter(unread, nil), hiding: confirmed}
	a.show(readyMessage)
	hidden := make(chan struct{})
	go func() {
		for range 3 {
			a.hide(told(a))
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
// mark nothing and say nothing, since no page of the shell's shows yet;
// after it each lock hides and is told.
func TestScreenApp_ReadyIsTheFirstMessage(t *testing.T) {
	sink := &lineSink{}
	marked := 0
	a := &screenApp{to: desktop.NewWriter(sink, nil), hiding: func() func() error { marked++; return func() error { return nil } }}
	a.hide(told(a))
	a.hide(told(a))
	if marked != 0 {
		t.Fatalf("a hide before ready marked %d times", marked)
	}
	a.show(readyMessage)
	a.hide(told(a))
	want := []string{desktop.TypeReady, desktop.TypeLocked}
	if said := sink.said(t, len(want)+1); strings.Join(said, ", ") != strings.Join(want, ", ") || marked != 1 {
		t.Fatalf("the shell said %v, marking %d times, want %v", said, marked, want)
	}
}

// ending is the last message: a second, a locked or anything else after
// it is not said, and a hide after it marks nothing.
func TestScreenApp_ItsLastLockSaysEndingAndNothingFollows(t *testing.T) {
	sink := &lineSink{}
	a := shown(sink)
	a.hide(func() { a.say(desktop.Message{Type: desktop.TypeEnding}) })
	a.hide(told(a))
	a.say(desktop.Message{Type: desktop.TypeLeft, ID: 1})
	want := []string{desktop.TypeReady, desktop.TypeEnding}
	if said := sink.said(t, len(want)+1); strings.Join(said, ", ") != strings.Join(want, ", ") {
		t.Fatalf("the shell said %v, want %v", said, want)
	}
}

// A hide is the compositor's to confirm, never main's: what is shown is
// marked as the hide begins, before main is told anything; one confirmed
// ends nothing; one not confirmed, or unconfirmable, ends the app from
// outside with why, at most once whatever more hides fail, and the shell's
// last hide (ending) is held to it the same way. Each hide still returns
// at once.
func TestScreenApp_AHideNotConfirmedEndsTheApp(t *testing.T) {
	type hide struct {
		told int // what main had been told as the hide began
		gone chan error
	}
	setUp := func() (*screenApp, *lineSink, chan hide, chan error) {
		sink := &lineSink{}
		hides, ended := make(chan hide, 8), make(chan error, 8)
		a := &screenApp{to: desktop.NewWriter(sink, nil), endApp: func(why error) { ended <- why }}
		a.show(readyMessage)
		sink.said(t, 1)
		a.hiding = func() func() error {
			// Anything main was told before the mark reaches the sink well
			// within this.
			time.Sleep(100 * time.Millisecond) // sleep-ok: lets a message queued before the mark be written
			h := hide{told: len(sink.said(t, 0)), gone: make(chan error, 1)}
			hides <- h
			return func() error { return <-h.gone }
		}
		return a, sink, hides, ended
	}
	nextHide := func(hides chan hide) hide {
		t.Helper()
		select {
		case h := <-hides:
			return h
		case <-time.After(5 * time.Second):
			t.Fatal("a hide marked nothing")
			return hide{}
		}
	}
	noEnd := func(ended chan error) {
		t.Helper()
		select {
		case why := <-ended:
			t.Fatalf("the app was ended: %v", why)
		case <-time.After(50 * time.Millisecond):
		}
	}

	a, _, hides, ended := setUp()
	a.hide(told(a))
	h := nextHide(hides)
	if h.told != 1 {
		t.Fatalf("main had been told %d messages as the hide began, want ready alone", h.told)
	}
	h.gone <- nil
	noEnd(ended)

	a.hide(told(a))
	h = nextHide(hides)
	stuck := errors.New("the compositor still shows 1 of the 1 windows shown then after 2s")
	h.gone <- stuck
	select {
	case why := <-ended:
		if why != stuck {
			t.Fatalf("the app was ended saying %v", why)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("a hide not confirmed ended nothing")
	}
	a.hide(told(a))
	nextHide(hides).gone <- errors.New("the compositor's list of windows cannot be read")
	noEnd(ended)

	b, _, bHides, bEnded := setUp()
	b.hide(func() { b.say(desktop.Message{Type: desktop.TypeEnding}) })
	nextHide(bHides).gone <- stuck
	select {
	case <-bEnded:
	case <-time.After(5 * time.Second):
		t.Fatal("the shell's last hide, not confirmed, ended nothing")
	}
}

// ending is the last message of the shell's run: a leave the shell's last
// lock answers gets no left after it (tests/fixtures/desktop-process.json
// endings), the screen's service ended before main's messages are read.
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
			t.Setenv("HOME", t.TempDir())
			sink := &lineSink{}
			a := shown(sink)
			svc := newDesktopService(t.Context(), t.TempDir(), t.TempDir(), a.say)
			svc.Box, svc.Hide = "/home/box/cyfr", a.hide
			svc.End()
			if err := svc.Run(strings.NewReader(strings.Join(lines, "\n"))); err != nil {
				t.Fatal(err)
			}
			want := []string{desktop.TypeReady}
			for _, m := range c.FromCyfr {
				want = append(want, m.Type)
			}
			if said := sink.said(t, len(want)+1); strings.Join(said, ", ") != strings.Join(want, ", ") {
				t.Fatalf("the shell said %v, want %v", said, want)
			}
		})
	}
}

// TestScreenAppFinishHelper is the process of
// TestScreenApp_TheLastHideOutlivesNoProcess: it ends the shell with a
// last hide whose confirmation comes late and fails, then the process
// ends at once.
func TestScreenAppFinishHelper(t *testing.T) {
	dir := os.Getenv("CYFR_SCREEN_FINISH_DIR")
	if dir == "" {
		t.Skip("run by TestScreenApp_TheLastHideOutlivesNoProcess")
	}
	a := &screenApp{to: desktop.NewWriter(&lineSink{}, nil),
		hiding: func() func() error {
			return func() error {
				time.Sleep(300 * time.Millisecond) // sleep-ok: a confirmation that comes late
				return errors.New("the compositor still shows 1 of the 1 windows")
			}
		},
		endApp: func(why error) { _ = os.WriteFile(filepath.Join(dir, "ended"), []byte(why.Error()), 0o600) }}
	a.show(readyMessage)
	a.hide(func() { a.say(desktop.Message{Type: desktop.TypeEnding}) })
	a.finish()
	os.Exit(0)
}

// The shell's last hide is confirmed or carried out before the shell
// returns: a process that ends right after it leaves none undone.
func TestScreenApp_TheLastHideOutlivesNoProcess(t *testing.T) {
	dir := t.TempDir()
	helper := exec.Command(os.Args[0], "-test.run=^TestScreenAppFinishHelper$")
	helper.Env = append(os.Environ(), "CYFR_SCREEN_FINISH_DIR="+dir)
	if out, err := helper.CombinedOutput(); err != nil {
		t.Fatalf("the helper: %v\n%s", err, out)
	}
	if why, err := os.ReadFile(filepath.Join(dir, "ended")); err != nil || !strings.Contains(string(why), "still shows") {
		t.Fatalf("the process ended before its last hide was carried out: %q (%v)", why, err)
	}
}
