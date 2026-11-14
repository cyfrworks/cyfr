// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package cmd

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"sync"
	"syscall"
	"testing"

	"golang.org/x/sys/unix"
)

// onATerminal gives the command a terminal of its own, a pseudo-terminal
// on stdin and stdout, until t ends: a version-less reference is then
// looked up before the run, as a person at a terminal has it looked up.
func onATerminal(t *testing.T) {
	t.Helper()
	t.Setenv("CYFR_NO_INTERACTIVE", "")
	ptmx, err := os.OpenFile("/dev/ptmx", os.O_RDWR|syscall.O_NOCTTY, 0)
	if err != nil {
		t.Fatalf("opening a pseudo-terminal: %v", err)
	}
	fd := int(ptmx.Fd())
	if err := unix.IoctlSetPointerInt(fd, unix.TIOCSPTLCK, 0); err != nil {
		t.Fatalf("unlocking the pseudo-terminal: %v", err)
	}
	n, err := unix.IoctlGetInt(fd, unix.TIOCGPTN)
	if err != nil {
		t.Fatalf("naming the pseudo-terminal: %v", err)
	}
	pts, err := os.OpenFile(fmt.Sprintf("/dev/pts/%d", n), os.O_RDWR|syscall.O_NOCTTY, 0)
	if err != nil {
		t.Fatalf("opening the terminal's side: %v", err)
	}
	// What the command writes to the terminal is read and dropped, so a
	// full buffer never holds it.
	go func() { _, _ = io.Copy(io.Discard, ptmx) }()

	stdin, stdout := os.Stdin, os.Stdout
	os.Stdin, os.Stdout = pts, pts
	t.Cleanup(func() {
		os.Stdin, os.Stdout = stdin, stdout
		pts.Close()
		ptmx.Close()
	})
}

// runAtTerminal runs the command line with args under ctx, its output on
// the terminal, and answers its error.
func runAtTerminal(ctx context.Context, args ...string) error {
	forgetFlags := func() {
		flagJSON, flagURL, flagContext, flagNoInteractive, flagToken = false, "", "", false, ""
		rootCmd.SetArgs(nil)
	}
	forgetFlags()
	defer forgetFlags()
	rootCmd.SetContext(nil)
	runCmd.SetContext(nil)
	rootCmd.SetArgs(args)
	return Execute(ctx)
}

// lookupServer answers nothing until the request's own end, and records
// the tool each request names; asked is closed at the first.
type lookupServer struct {
	*httptest.Server
	mu     sync.Mutex
	tools  []string
	asked  chan struct{}
	once   sync.Once
	ended  chan struct{}
	answer string
}

func newLookupServer(t *testing.T, answer string) *lookupServer {
	t.Helper()
	s := &lookupServer{asked: make(chan struct{}), ended: make(chan struct{}), answer: answer}
	s.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw, _ := io.ReadAll(r.Body)
		s.mu.Lock()
		s.tools = append(s.tools, string(raw))
		s.mu.Unlock()
		s.once.Do(func() { close(s.asked) })
		if s.answer == "" {
			select {
			case <-r.Context().Done():
			case <-s.ended:
			}
			return
		}
		w.Header().Set("Content-Type", "application/json")
		io.WriteString(w, s.answer)
	}))
	// Cleanups run last first: the handler is let go before the server
	// waits for it.
	t.Cleanup(s.Close)
	t.Cleanup(func() { close(s.ended) })
	return s
}

func (s *lookupServer) requests() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]string(nil), s.tools...)
}

// Ctrl-C while the reference's versions are looked up ends the command as
// the person's interruption, exit 130, saying nothing was started; the run
// is never asked for.
func TestRun_CtrlCDuringTheLookupStartsNothing(t *testing.T) {
	forgetRunFlags(t)
	t.Setenv("HOME", t.TempDir())
	t.Setenv("CYFR_TOKEN", "cyfr-test-session")
	srv := newLookupServer(t, "")
	onATerminal(t)

	err := interruptAt(t, srv.asked, func(ctx context.Context) error {
		return runAtTerminal(ctx, "run", "reagent:local.math", "--url", srv.URL)
	})

	wantInterrupted(t, err, "Interrupted; nothing was started.")
	if got := srv.requests(); len(got) != 1 {
		t.Fatalf("the server was asked %d times, want only the lookup: %v", len(got), got)
	}
}

// An --input that is not a JSON object is refused before the reference is
// looked up: the server is asked nothing.
func TestRun_ANonObjectInputSendsNothing(t *testing.T) {
	forgetRunFlags(t)
	t.Setenv("HOME", t.TempDir())
	t.Setenv("CYFR_TOKEN", "cyfr-test-session")
	srv := newLookupServer(t, `{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"{}"}]}}`)
	onATerminal(t)

	err := runAtTerminal(context.Background(), "run", "reagent:local.math", "--input", "[1,2]", "--url", srv.URL)

	if err == nil || err.Error() != `The input must be a JSON object, such as '{"text":"hello"}'.` {
		t.Fatalf("the array input answered %v", err)
	}
	if got := srv.requests(); len(got) != 0 {
		t.Fatalf("the server was asked %d times: %v", len(got), got)
	}
}
