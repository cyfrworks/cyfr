// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build unix

package wayland

import (
	"bufio"
	"bytes"
	"encoding/hex"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// labwc stands in for itself by its recorded exchange (testdata): it holds
// each request the list makes to the recorded one, byte for byte, and
// sends each recorded event, stopping at each step until the test plays
// it. Beside the recording it answers each round trip the list asks at
// once, playing first the step armed to arrive with it, takes any closed
// window's destroy, and sends what the test injects; it ends
// the connection when the test ends it. As labwc's libwayland does, it
// refuses a round trip's callback numbered other than the next one, and
// ends the connection.
type labwc struct {
	socket string
	steps  chan struct{}
	failed chan string
	synced chan struct{}

	mu    sync.Mutex
	conn  net.Conn
	armed bool
	// sync is the number the next round trip's callback must have.
	sync uint32
	// played is each step's events, in order, and what of them was sent.
	pending [][][]byte
	asked   [][]byte
	ended   chan struct{}
}

func replay(t *testing.T, file string) *labwc {
	t.Helper()
	raw, err := os.ReadFile(file)
	if err != nil {
		t.Fatal(err)
	}
	l := &labwc{socket: filepath.Join(t.TempDir(), "wayland-0"), steps: make(chan struct{}, 8), failed: make(chan string, 8),
		synced: make(chan struct{}, 1024), ended: make(chan struct{}), sync: firstSync}
	// The recording cut at its steps: what labwc sends in each, and what
	// it is asked across them all, in order.
	l.pending = [][][]byte{nil}
	for _, line := range strings.Split(strings.TrimSpace(string(raw)), "\n") {
		kind, rest, _ := strings.Cut(line, " ")
		switch kind {
		case "=":
			l.pending = append(l.pending, nil)
		case "c", "s":
			b, err := hex.DecodeString(rest)
			if err != nil {
				t.Fatal(line)
			}
			if kind == "s" {
				l.pending[len(l.pending)-1] = append(l.pending[len(l.pending)-1], b)
			} else {
				l.asked = append(l.asked, b)
			}
		}
	}
	ln, err := net.Listen("unix", l.socket)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close(); l.end() })
	go func() {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		l.mu.Lock()
		l.conn = c
		l.mu.Unlock()
		l.play()
		go l.hear(c)
		for range l.steps {
			l.play()
		}
	}()
	return l
}

// play sends the next step's events.
func (l *labwc) play() {
	l.mu.Lock()
	defer l.mu.Unlock()
	if len(l.pending) == 0 {
		return
	}
	for _, b := range l.pending[0] {
		_, _ = l.conn.Write(b)
	}
	l.pending = l.pending[1:]
}

// hear reads what the list asks.
func (l *labwc) hear(c net.Conn) {
	r := bufio.NewReader(c)
	for {
		var head [8]byte
		if _, err := io.ReadFull(r, head[:]); err != nil {
			return
		}
		body := make([]byte, Wire.Uint32(head[4:])>>16-8)
		if _, err := io.ReadFull(r, body); err != nil {
			return
		}
		msg := append(head[:], body...)
		object, opcode := Wire.Uint32(head[:]), Wire.Uint32(head[4:])&0xffff
		l.mu.Lock()
		switch {
		case object == Display && opcode == DisplaySync && Wire.Uint32(body) >= firstSync && Wire.Uint32(body) != l.sync:
			l.failed <- fmt.Sprintf("the list numbered a round trip %d where labwc takes only %d", Wire.Uint32(body), l.sync)
			l.mu.Unlock()
			c.Close()
			return
		case object == Display && opcode == DisplaySync && Wire.Uint32(body) >= firstSync:
			l.sync++
			if l.armed {
				l.armed = false
				for _, b := range l.pending[0] {
					_, _ = c.Write(b)
				}
				l.pending = l.pending[1:]
			}
			id := Wire.Uint32(body)
			_, _ = c.Write(Words(id, 12<<16|CallbackDone, 1))
			_, _ = c.Write(Words(Display, 12<<16|DisplayDeleteID, id))
			l.synced <- struct{}{}
		case opcode == handleDestroy && object >= a && len(body) == 0:
			// A window's destroy once labwc closed it, recorded or not.
		case len(l.asked) > 0 && bytes.Equal(msg, l.asked[0]):
			l.asked = l.asked[1:]
		default:
			l.failed <- "the list asked " + hex.EncodeToString(msg) + ", which labwc was not asked"
		}
		l.mu.Unlock()
	}
}

// step plays the recording's next step; armStep plays it with the next
// round trip's answer, ahead of its done.
func (l *labwc) step()    { l.steps <- struct{}{} }
func (l *labwc) armStep() { l.mu.Lock(); l.armed = true; l.mu.Unlock() }

// close injects labwc closing the window it numbers handle; open
// injects it announcing a new window it numbers handle.
func (l *labwc) close(handle uint32) {
	l.mu.Lock()
	defer l.mu.Unlock()
	_, _ = l.conn.Write(Words(handle, 8<<16|handleClosed))
}

func (l *labwc) open(handle uint32) {
	l.mu.Lock()
	defer l.mu.Unlock()
	_, _ = l.conn.Write(Words(windowsManager, 12<<16|managerToplevel, handle))
}

func (l *labwc) end() {
	l.mu.Lock()
	defer l.mu.Unlock()
	select {
	case <-l.ended:
	default:
		close(l.ended)
		if l.conn != nil {
			l.conn.Close()
		}
	}
}

func (l *labwc) roundTrip(t *testing.T) {
	t.Helper()
	select {
	case <-l.synced:
	case why := <-l.failed:
		t.Fatal(why)
	case <-time.After(5 * time.Second):
		t.Fatal("the list asked no round trip")
	}
}

// shows waits until the list shows n windows, as far as it has read.
func shows(t *testing.T, w *Windows, n int) {
	t.Helper()
	for deadline := time.Now().Add(5 * time.Second); ; {
		if m := w.Mark(0); m.err == nil && len(m.windows) == n {
			return
		}
		if time.Now().After(deadline) {
			m := w.Mark(0)
			t.Fatalf("the list shows %d windows (%v), want %d", len(m.windows), m.err, n)
		}
		time.Sleep(5 * time.Millisecond) // sleep-ok: polls the list's own reader, bounded
	}
}

const a, b, c = 0xff000000, 0xff000001, 0xff000002

// The list as labwc told it, and a hide's mark against it: a window
// announced just before the mark, in transit as it was taken, is marked
// by the round trip; the marked windows closing confirm it even where a
// new window then takes a closed one's number; an empty list is
// confirmed once the round trip shows it truly empty; and once labwc has
// gone nothing is confirmed. Each round trip is the list's own.
func TestWindows_AsLabwcTellsThem(t *testing.T) {
	l := replay(t, "testdata/labwc-windows.txt")
	t.Setenv("WAYLAND_DISPLAY", l.socket)
	w := ListWindows(t.Context())
	t.Cleanup(func() { w.Close() })
	shows(t, w, 2)

	// The third window's announcement arrives only with the round trip.
	l.armStep()
	if err := w.Mark(200 * time.Millisecond).Closed(); err == nil || !strings.Contains(err.Error(), "still shows 3 of the 3") {
		t.Fatalf("a window announced before the round trip was not marked: %v", err)
	}
	l.roundTrip(t)

	l.step() // one of the first two closes
	shows(t, w, 2)

	mark := w.Mark(5 * time.Second)
	closed := make(chan error, 1)
	go func() { closed <- mark.Closed() }()
	l.roundTrip(t)
	l.close(c)
	l.open(c) // a new window, numbered as the closed one was
	l.step()  // the other closes
	if err := <-closed; err != nil {
		t.Fatalf("the marked windows closed, a new one numbered as one of them, and the hide was not confirmed: %v", err)
	}
	shows(t, w, 1)

	l.close(c)
	shows(t, w, 0)
	if err := w.Mark(time.Second).Closed(); err != nil {
		t.Fatalf("an empty list was not confirmed: %v", err)
	}
	l.roundTrip(t)

	l.end()
	for deadline := time.Now().Add(5 * time.Second); w.Mark(0).err == nil; {
		if time.Now().After(deadline) {
			t.Fatal("the list went on after labwc's end")
		}
		time.Sleep(5 * time.Millisecond) // sleep-ok: polls the list's own reader, bounded
	}
	if err := w.Mark(time.Second).Closed(); err == nil || !strings.Contains(err.Error(), "cannot be read") {
		t.Fatalf("after labwc's end a hide was %v", err)
	}
	select {
	case why := <-l.failed:
		t.Fatal(why)
	default:
	}
}

// A compositor the list cannot be read from says why from the start: none
// at the socket, and one that offers no list of its windows.
func TestWindows_ThatCannotBeRead(t *testing.T) {
	t.Setenv("WAYLAND_DISPLAY", filepath.Join(t.TempDir(), "none"))
	w := ListWindows(t.Context())
	if err := w.Mark(time.Second).Closed(); err == nil {
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
	if err := w.Mark(time.Second).Closed(); err == nil || !strings.Contains(err.Error(), "offers no list of its windows") {
		t.Fatalf("a compositor without a list of windows: %v", err)
	}
}

// deafCompositor lists the windows' manager and reads nothing more. With
// windows, it then opens and closes windows at the list: each closed
// window's destroy fills its socket, until the list's reader waits on a
// write; stalled is closed once the compositor's own writes no longer go
// through, as the reader no longer reads: it waits on that write.
func deafCompositor(t *testing.T, windows bool) (socket string, stalled <-chan struct{}) {
	t.Helper()
	socket = filepath.Join(t.TempDir(), "wayland-0")
	ln, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	over, full := make(chan struct{}), make(chan struct{})
	t.Cleanup(func() { close(over); ln.Close() })
	go func() {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		var asked [60 + 12]byte
		if _, err := io.ReadFull(conn, asked[:24]); err != nil {
			return
		}
		global := append(Words(7, uint32(len(managerName)+1)), managerName...)
		global = append(global, 0)
		for len(global)%4 != 0 {
			global = append(global, 0)
		}
		global = append(global, Words(3)...)
		_, _ = conn.Write(append(Words(windowsRegistry, uint32(8+len(global))<<16|RegistryGlobal), global...))
		_, _ = conn.Write(Words(windowsListed, 12<<16|CallbackDone, 1))
		if _, err := io.ReadFull(conn, asked[:]); err != nil {
			return
		}
		_, _ = conn.Write(Words(windowsBound, 12<<16|CallbackDone, 1))
		// Windows opened and closed, each closed one's destroy asked of a
		// compositor that reads no more.
		for h := uint32(a); windows; h++ {
			_ = conn.SetWriteDeadline(time.Now().Add(200 * time.Millisecond))
			if _, err := conn.Write(append(Words(windowsManager, 12<<16|managerToplevel, h), Words(h, 8<<16|handleClosed)...)); err != nil {
				break
			}
		}
		close(full)
		<-over
	}()
	return socket, full
}

// A compositor that stops reading holds nothing of the list's: with its
// socket full of the list's requests, the list is marked at once all the
// same, and gives up within its bound, which confirms nothing.
func TestWindows_ACompositorThatDoesNotReadHoldsNothing(t *testing.T) {
	socket, _ := deafCompositor(t, true)
	t.Setenv("WAYLAND_DISPLAY", socket)
	w := ListWindows(t.Context())
	defer w.Close()
	began := time.Now()
	for time.Since(began) < 3*time.Second {
		at := time.Now()
		m := w.Mark(0)
		if took := time.Since(at); took > 200*time.Millisecond {
			t.Fatalf("a mark waited %v on a compositor that does not read", took)
		}
		if m.err != nil {
			break
		}
		time.Sleep(10 * time.Millisecond) // sleep-ok: marks again while the list writes
	}
	if err := w.Mark(time.Second).Closed(); err == nil || !strings.Contains(err.Error(), "cannot be read") {
		t.Fatalf("a compositor that does not read: %v", err)
	}
}

// A hide's round trip that waits its turn behind a slow write still ends
// at the hide's deadline, and so does one whose own write is slow: the
// turn and the write are on its road.
func TestWindows_AHideQueuedBehindASlowWriteEndsAtItsDeadline(t *testing.T) {
	socket, stalled := deafCompositor(t, true)
	t.Setenv("WAYLAND_DISPLAY", socket)
	w := ListWindows(t.Context())
	defer w.Close()
	select {
	case <-stalled:
	case <-time.After(5 * time.Second):
		t.Fatal("the list's reader never waited on a write")
	}
	const within = 300 * time.Millisecond
	mark := w.Mark(within)
	err := mark.Closed()
	if late := time.Since(mark.deadline); late > 150*time.Millisecond {
		t.Fatalf("a hide queued behind a slow write ended %v after its deadline (%v)", late, err)
	}
	if err == nil {
		t.Fatal("a hide was confirmed by a compositor that does not read")
	}
}

// Hides that overlap number their round trips in the order they reach
// labwc, which ends the connection at a number out of turn: every one of
// them is confirmed.
func TestWindows_OverlappingHidesNumberTheirRoundTripsInOrder(t *testing.T) {
	l := replay(t, "testdata/labwc-windows.txt")
	t.Setenv("WAYLAND_DISPLAY", l.socket)
	w := ListWindows(t.Context())
	t.Cleanup(func() { w.Close() })
	shows(t, w, 2)
	l.close(a)
	l.close(b)
	shows(t, w, 0)
	const hides = 200
	errs := make(chan error, hides)
	var begin sync.WaitGroup
	begin.Add(1)
	for range hides {
		go func() {
			begin.Wait()
			errs <- w.Mark(5 * time.Second).Closed()
		}()
	}
	begin.Done()
	for range hides {
		if err := <-errs; err != nil {
			select {
			case why := <-l.failed:
				t.Fatal(why)
			default:
			}
			t.Fatalf("an overlapping hide was not confirmed: %v", err)
		}
	}
}

func TestWindows_AHideWhoseWriteIsSlowEndsAtItsDeadline(t *testing.T) {
	socket, _ := deafCompositor(t, false)
	t.Setenv("WAYLAND_DISPLAY", socket)
	w := ListWindows(t.Context())
	defer w.Close()
	// The socket filled to the brim, in a turn of the list's own, which the
	// compositor never reads: the next write waits on it.
	w.turn <- struct{}{}
	for {
		_ = w.conn.SetWriteDeadline(time.Now().Add(100 * time.Millisecond))
		if err := w.conn.Send(Display, DisplaySync, Words(firstSync)); err != nil {
			break
		}
	}
	<-w.turn
	const within = 300 * time.Millisecond
	mark := w.Mark(within)
	err := mark.Closed()
	if late := time.Since(mark.deadline); late > 150*time.Millisecond {
		t.Fatalf("a hide whose write is slow ended %v after its deadline (%v)", late, err)
	}
	if err == nil {
		t.Fatal("a hide was confirmed by a compositor that does not read")
	}
}
