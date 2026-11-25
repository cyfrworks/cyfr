// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package main

import (
	"errors"
	"io"
	"net"
	"os"
	"testing"
	"time"

	"github.com/cyfr/locus/keeper/internal/frame"
	"golang.org/x/sys/unix"
)

// socketPair is a connected pair of Unix stream sockets, each a net.Conn
// whose writing side ends apart.
func socketPair(t *testing.T) (*net.UnixConn, *net.UnixConn) {
	t.Helper()
	fds, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_STREAM|unix.SOCK_CLOEXEC, 0)
	if err != nil {
		t.Fatal(err)
	}
	conns := make([]*net.UnixConn, 2)
	for i, fd := range fds {
		f := os.NewFile(uintptr(fd), "pair")
		c, err := net.FileConn(f)
		_ = f.Close()
		if err != nil {
			t.Fatal(err)
		}
		conns[i] = c.(*net.UnixConn)
		t.Cleanup(func() { _ = c.Close() })
	}
	return conns[0], conns[1]
}

// readAll reads c to its end within a bound.
func readAll(t *testing.T, c *net.UnixConn) string {
	t.Helper()
	_ = c.SetReadDeadline(time.Now().Add(5 * time.Second))
	b, err := io.ReadAll(c)
	if err != nil {
		t.Fatalf("reading to the end: %v", err)
	}
	return string(b)
}

// closed reports whether c's peer has closed: a read ends at once.
func closed(t *testing.T, c *net.UnixConn) bool {
	t.Helper()
	_ = c.SetReadDeadline(time.Now().Add(5 * time.Second))
	_, err := c.Read(make([]byte, 1))
	return errors.Is(err, io.EOF)
}

func TestOfferJoinsAHostHalfAndASpawnHalfOfOneToken(t *testing.T) {
	p := &pairs{waiting: map[string]*half{}}
	host, hostInside := socketPair(t)
	spawn, spawnInside := socketPair(t)
	p.offer("tok", hostInside, true)
	p.offer("tok", spawnInside, false)

	if _, err := host.Write([]byte("to the spawn")); err != nil {
		t.Fatal(err)
	}
	if err := host.CloseWrite(); err != nil {
		t.Fatal(err)
	}
	if got := readAll(t, spawn); got != "to the spawn" {
		t.Fatalf("the spawn read %q", got)
	}
	// The host's end of writing reached the spawn as an end of file; the
	// other way stays open until the spawn ends its own.
	if _, err := spawn.Write([]byte("to the host")); err != nil {
		t.Fatal(err)
	}
	if err := spawn.CloseWrite(); err != nil {
		t.Fatal(err)
	}
	if got := readAll(t, host); got != "to the host" {
		t.Fatalf("the host read %q", got)
	}
	if len(p.waiting) != 0 {
		t.Fatalf("%d halves still wait", len(p.waiting))
	}
}

func TestOfferEndsTwoHalvesFromOneSide(t *testing.T) {
	for _, host := range []bool{true, false} {
		p := &pairs{waiting: map[string]*half{}}
		a, aInside := socketPair(t)
		b, bInside := socketPair(t)
		p.offer("tok", aInside, host)
		p.offer("tok", bInside, host)
		if !closed(t, a) || !closed(t, b) {
			t.Fatalf("host=%v: two halves of one side were not both closed", host)
		}
		if len(p.waiting) != 0 {
			t.Fatalf("host=%v: %d halves still wait", host, len(p.waiting))
		}
	}
}

func TestOfferClosesAnUnpairedHalfAfterPairWait(t *testing.T) {
	was := pairWait
	pairWait = 50 * time.Millisecond
	t.Cleanup(func() { pairWait = was })
	p := &pairs{waiting: map[string]*half{}}
	a, aInside := socketPair(t)
	p.offer("tok", aInside, true)
	if !closed(t, a) {
		t.Fatal("an unpaired half was not closed")
	}
	p.mu.Lock()
	left := len(p.waiting)
	p.mu.Unlock()
	if left != 0 {
		t.Fatalf("%d halves still wait", left)
	}
}

func TestTokenReadsTheAttachFrame(t *testing.T) {
	a, b := socketPair(t)
	go func() { _ = frame.Write(a, frame.StreamAttach, []byte("tok")) }()
	got, err := token(b, b.SetReadDeadline)
	if err != nil || got != "tok" {
		t.Fatalf("token gave %q, %v", got, err)
	}
}

func TestTokenRefusesAnotherFirstFrame(t *testing.T) {
	for _, f := range []struct {
		stream  byte
		payload string
	}{{frame.StreamStdout, "tok"}, {frame.StreamAttach, ""}} {
		a, b := socketPair(t)
		go func() { _ = frame.Write(a, f.stream, []byte(f.payload)) }()
		if got, err := token(b, b.SetReadDeadline); err == nil {
			t.Fatalf("stream %d %q was taken as token %q", f.stream, f.payload, got)
		}
	}
}

// The attach socket admits maxUnmatched connections not yet matched and
// refuses one more at once, while those it holds stay open: a stand-in
// that keeps connecting, and never presents a token.
func TestAttachRefusesAConnectionPastTheUnmatchedBound(t *testing.T) {
	path := t.TempDir() + "/attach.sock"
	l, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = l.Close() })
	p := &pairs{waiting: map[string]*half{}}
	go acceptAttach(l, p)
	dial := func() *net.UnixConn {
		c, err := net.Dial("unix", path)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = c.Close() })
		return c.(*net.UnixConn)
	}
	held := make([]*net.UnixConn, 0, maxUnmatched)
	for i := 0; i < maxUnmatched; i++ {
		held = append(held, dial())
	}
	one := dial()
	_ = one.SetReadDeadline(time.Now().Add(5 * time.Second))
	if _, err := one.Read(make([]byte, 1)); !errors.Is(err, io.EOF) {
		t.Fatalf("connection %d past the bound of %d was not refused at once: %v", maxUnmatched+1, maxUnmatched, err)
	}
	for _, c := range held[:1] {
		_ = c.SetReadDeadline(time.Now().Add(200 * time.Millisecond))
		if _, err := c.Read(make([]byte, 1)); !errors.Is(err, os.ErrDeadlineExceeded) {
			t.Fatalf("a connection within the bound did not stay open: %v", err)
		}
	}
	p.mu.Lock()
	counted := p.unmatched
	p.mu.Unlock()
	if counted != maxUnmatched {
		t.Fatalf("%d connections are counted unmatched, not %d", counted, maxUnmatched)
	}
}
