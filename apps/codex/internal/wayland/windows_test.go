// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build unix

package wayland

import (
	"bufio"
	"bytes"
	"encoding/hex"
	"io"
	"net"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
)

// labwc stands in for itself by its recorded exchange (testdata): it reads
// each request the list makes and holds it to the recorded one, byte for
// byte, and sends each recorded event, stopping at each step until the
// test sends on next; after the last it ends the connection.
type labwc struct {
	socket string
	next   chan struct{}
	failed chan string
}

func replay(t *testing.T, file string) *labwc {
	t.Helper()
	raw, err := os.ReadFile(file)
	if err != nil {
		t.Fatal(err)
	}
	l := &labwc{socket: filepath.Join(t.TempDir(), "wayland-0"), next: make(chan struct{}), failed: make(chan string, 1)}
	ln, err := net.Listen("unix", l.socket)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		defer c.Close()
		for _, line := range strings.Split(strings.TrimSpace(string(raw)), "\n") {
			kind, rest, _ := strings.Cut(line, " ")
			switch kind {
			case "#":
			case "=":
				<-l.next
			case "c", "s":
				want, err := hex.DecodeString(rest)
				if err != nil {
					l.failed <- line
					return
				}
				if kind == "s" {
					if _, err := c.Write(want); err != nil {
						l.failed <- "the list went before labwc sent " + rest
						return
					}
					continue
				}
				got := make([]byte, len(want))
				if _, err := io.ReadFull(c, got); err != nil || !bytes.Equal(got, want) {
					l.failed <- "the list asked " + hex.EncodeToString(got) + ", labwc was asked " + rest
					return
				}
			}
		}
	}()
	return l
}

func (l *labwc) step(t *testing.T) {
	t.Helper()
	select {
	case l.next <- struct{}{}:
	case why := <-l.failed:
		t.Fatal(why)
	case <-time.After(5 * time.Second):
		t.Fatal("labwc's recording did not reach its next step")
	}
}

// shows waits until the list shows exactly want.
func shows(t *testing.T, w *Windows, want ...uint32) {
	t.Helper()
	for deadline := time.Now().Add(5 * time.Second); ; {
		shown, err := w.Shown()
		if err == nil && slices.Equal(shown, want) {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("the list shows %v (%v), want %v", shown, err, want)
		}
		time.Sleep(5 * time.Millisecond) // sleep-ok: polls the list's own reader, bounded
	}
}

const a, b, c = 0xff000000, 0xff000001, 0xff000002

// The list as labwc told it: the windows shown as it began, a window
// opened after, one closed, which it confirms within its bound and no
// other, and nothing once labwc has gone, a window still shown then
// included: a list that cannot be read confirms nothing.
func TestWindows_AsLabwcTellsThem(t *testing.T) {
	l := replay(t, "testdata/labwc-windows.txt")
	t.Setenv("WAYLAND_DISPLAY", l.socket)
	w := ListWindows(t.Context())
	t.Cleanup(func() { w.Close() })
	shows(t, w, a, b)

	l.step(t)
	shows(t, w, a, b, c)

	closed := make(chan error, 1)
	go func() { closed <- w.Closed([]uint32{b}, 5*time.Second) }()
	l.step(t)
	if err := <-closed; err != nil {
		t.Fatalf("the closed window was not confirmed: %v", err)
	}
	shows(t, w, a, c)
	if err := w.Closed([]uint32{c}, 20*time.Millisecond); err == nil || !strings.Contains(err.Error(), "still shows 1 of the 1") {
		t.Fatalf("a window still shown was confirmed closed: %v", err)
	}
	if err := w.Closed(nil, time.Millisecond); err != nil {
		t.Fatalf("no window to close was not confirmed: %v", err)
	}

	go func() { closed <- w.Closed([]uint32{a, c}, 5*time.Second) }()
	l.step(t)
	if err := <-closed; err == nil || !strings.Contains(err.Error(), "cannot be read") {
		t.Fatalf("the end of labwc's connection, a window still shown, was %v", err)
	}
	if shown, err := w.Shown(); err == nil || !strings.Contains(err.Error(), "cannot be read") {
		t.Fatalf("after labwc's end the list shows %v (%v)", shown, err)
	}
	if err := w.Closed(nil, time.Millisecond); err == nil {
		t.Fatal("a list that cannot be read confirmed a hide")
	}
}

// A compositor the list cannot be read from says why from the start: none
// at the socket, and one that offers no list of its windows.
func TestWindows_ThatCannotBeRead(t *testing.T) {
	t.Setenv("WAYLAND_DISPLAY", filepath.Join(t.TempDir(), "none"))
	w := ListWindows(t.Context())
	if _, err := w.Shown(); err == nil {
		t.Fatal("a compositor that is not there was read")
	}

	socket := filepath.Join(t.TempDir(), "wayland-0")
	ln, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go func() {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		defer c.Close()
		r := bufio.NewReader(c)
		var asked [24]byte
		if _, err := io.ReadFull(r, asked[:]); err != nil {
			return
		}
		// Its registry lists a seat alone, then the round trip's done.
		seat := append(Words(1, 8), "wl_seat\x00"...)
		seat = append(seat, Words(9)...)
		_, _ = c.Write(append(Words(windowsRegistry, uint32(8+len(seat))<<16|RegistryGlobal), seat...))
		_, _ = c.Write(Words(windowsListed, 12<<16|CallbackDone, 1))
		_, _ = io.Copy(io.Discard, r)
	}()
	t.Setenv("WAYLAND_DISPLAY", socket)
	w = ListWindows(t.Context())
	defer w.Close()
	if _, err := w.Shown(); err == nil || !strings.Contains(err.Error(), "offers no list of its windows") {
		t.Fatalf("a compositor without a list of windows: %v", err)
	}
}
