// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package wayland

import (
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"sync"
	"time"
)

// The objects the list of windows names, in the order it makes them, and
// the requests and events of zwlr_foreign_toplevel_manager_v1 and its
// handles it uses, by their opcodes, at version 1.
const (
	windowsRegistry uint32 = iota + 2
	windowsListed
	windowsManager
	windowsBound
)

const (
	managerName      = "zwlr_foreign_toplevel_manager_v1"
	managerToplevel  = 0
	managerFinished  = 1
	handleClosed     = 6
	handleLastEvent  = 5 // title, app_id, output_enter, output_leave, state, done
	handleDestroy    = 7
	listWindowsAfter = 5 * time.Second
	// talkWithin bounds each message read and each request written: no
	// wait on the compositor's socket is longer.
	talkWithin = 2 * time.Second
	// firstSync is the first of the round trips' callbacks, each a new id.
	firstSync = windowsBound + 1
)

// Windows is the compositor's own list of the windows it shows
// (zwlr_foreign_toplevel_manager_v1), as it opens and closes them, read
// for as long as the connection lasts: the one word on what a person at
// the screen sees that comes from no program showing it. A window is the
// object the compositor announced, for its life: the number it named it
// by may name another window after it closed. A list that cannot be read,
// or no longer is, says why, and from then on that is all it says: it
// confirms nothing. Nothing that holds the list waits on the socket: each
// read and each write has its deadline, and the writes are made outside
// the list's lock.
type Windows struct {
	conn *Conn
	// name is the manager's global, whose removal ends the list.
	name uint32
	// wmu orders the writes and their deadlines.
	wmu sync.Mutex

	mu sync.Mutex
	// shown is each window shown now, by the number it has while it lives.
	shown map[uint32]*window
	// announced counts the windows announced so far.
	announced uint64
	// syncs is each round trip under way, by its callback, answered with
	// what is shown as its done arrives.
	syncs map[uint32]chan []*window
	next  uint32
	err   error
	// changed is closed at each change, and made anew.
	changed chan struct{}
}

// window is one window, from its announcement to its close.
type window struct {
	order  uint64 // its place among the announcements
	closed bool
}

// ListWindows reads the list of windows of the compositor a client finds
// (Socket), the ones shown already first, until Close or the connection's
// end. It returns once the compositor has listed them, or has failed to
// within its bound, which the list then says.
func ListWindows(ctx context.Context) *Windows {
	w := &Windows{shown: map[uint32]*window{}, syncs: map[uint32]chan []*window{}, next: firstSync, changed: make(chan struct{})}
	socket, err := Socket()
	if err != nil {
		w.err = err
		return w
	}
	ctx, cancel := context.WithTimeout(ctx, listWindowsAfter)
	defer cancel()
	conn, err := (&net.Dialer{}).DialContext(ctx, "unix", socket)
	if err != nil {
		w.err = err
		return w
	}
	w.conn = NewConn(conn)
	stop := context.AfterFunc(ctx, func() { _ = conn.Close() })
	err = w.list()
	if !stop() {
		err = errors.Join(err, ctx.Err())
	}
	if err != nil {
		_ = conn.Close()
		w.err = err
		return w
	}
	go w.read()
	return w
}

// list binds the manager and reads what it lists at once, to a round trip.
func (w *Windows) list() error {
	if err := w.send(Display, DisplayGetRegistry, Words(windowsRegistry)); err != nil {
		return err
	}
	if err := w.send(Display, DisplaySync, Words(windowsListed)); err != nil {
		return err
	}
	found := false
	for {
		m, err := w.conn.Next()
		if err != nil {
			return err
		}
		if m.Object == windowsListed && m.Opcode == CallbackDone {
			break
		}
		if m.Object != windowsRegistry || m.Opcode != RegistryGlobal {
			continue
		}
		name, iface, _, err := m.Global()
		if err != nil {
			return err
		}
		if iface == managerName && !found {
			found, w.name = true, name
		}
	}
	if !found {
		return errors.New("the compositor offers no list of its windows (" + managerName + ")")
	}
	if err := w.send(windowsRegistry, RegistryBind, Bind(w.name, managerName, 1, windowsManager)); err != nil {
		return err
	}
	if err := w.send(Display, DisplaySync, Words(windowsBound)); err != nil {
		return err
	}
	for {
		m, err := w.conn.Next()
		if err != nil {
			return err
		}
		if m.Object == windowsBound && m.Opcode == CallbackDone {
			return nil
		}
		if err := w.take(m); err != nil {
			return err
		}
	}
}

// send writes one request within talkWithin, never under the list's lock.
func (w *Windows) send(object, opcode uint32, body []byte) error {
	w.wmu.Lock()
	defer w.wmu.Unlock()
	if err := w.conn.SetWriteDeadline(time.Now().Add(talkWithin)); err != nil {
		return err
	}
	return w.conn.Send(object, opcode, body)
}

// read takes each event as it comes: the wait for one to begin is
// unbounded, as a compositor with nothing to tell is silent, but each
// message begun is read within talkWithin.
func (w *Windows) read() {
	for {
		err := w.conn.SetReadDeadline(time.Now().Add(talkWithin))
		if err == nil {
			if err = w.conn.Peek(); errors.Is(err, os.ErrDeadlineExceeded) {
				continue
			}
		}
		var m Message
		if err == nil {
			if err = w.conn.SetReadDeadline(time.Now().Add(talkWithin)); err == nil {
				m, err = w.conn.Next()
			}
		}
		if err == nil {
			err = w.take(m)
		}
		if err != nil {
			w.fail(err)
			return
		}
	}
}

func (w *Windows) fail(err error) {
	w.mu.Lock()
	if w.err == nil {
		w.err = err
	}
	w.change()
	w.mu.Unlock()
	_ = w.conn.Close()
}

// take takes in one event, and sends what it answers after: a closed
// window's destroy.
func (w *Windows) take(m Message) error {
	closed, err := w.place(m)
	if err != nil || !closed {
		return err
	}
	return w.send(m.Object, handleDestroy, nil)
}

// place takes in one event under the list's lock: a window opened or
// closed (closed says it), a round trip's done, nothing for what it says
// of a window or a deletion, and why the list is lost for any other.
func (w *Windows) place(m Message) (closed bool, err error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	shown := w.shown[m.Object]
	switch {
	case m.Object == windowsManager && m.Opcode == managerToplevel && len(m.Body) == 4:
		w.announced++
		w.shown[Wire.Uint32(m.Body)] = &window{order: w.announced}
		w.change()
		return false, nil
	case m.Object == windowsManager && m.Opcode == managerFinished:
		return false, errors.New("the compositor stopped listing its windows")
	case shown != nil && m.Opcode == handleClosed:
		shown.closed = true
		delete(w.shown, m.Object)
		w.change()
		return true, nil
	case shown != nil && m.Opcode <= handleLastEvent:
		return false, nil
	case w.syncs[m.Object] != nil && m.Opcode == CallbackDone:
		now := make([]*window, 0, len(w.shown))
		for _, s := range w.shown {
			now = append(now, s)
		}
		w.syncs[m.Object] <- now
		delete(w.syncs, m.Object)
		return false, nil
	case m.Object == Display && m.Opcode == DisplayDeleteID:
		return false, nil
	case m.Object == windowsRegistry && m.Opcode == RegistryGlobal:
		_, _, _, err := m.Global()
		return false, err
	case m.Object == windowsRegistry && m.Opcode == RegistryGlobalRemove && len(m.Body) == 4:
		if Wire.Uint32(m.Body) == w.name {
			return false, errors.New("the compositor took away its list of windows")
		}
		return false, nil
	}
	return false, fmt.Errorf("the compositor sent an event the list of windows cannot place (object %d, opcode %d)", m.Object, m.Opcode)
}

// change wakes whoever waits on the list; the caller holds w.mu.
func (w *Windows) change() {
	close(w.changed)
	w.changed = make(chan struct{})
}

// Mark is what the list showed as a hide began, to be confirmed gone.
type Mark struct {
	w       *Windows
	windows []*window
	after   uint64
	err     error
}

// Mark marks the windows the list shows now, as far as it has read, with
// no wait on the compositor: Closed makes the mark current first.
func (w *Windows) Mark() Mark {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.err != nil {
		return Mark{err: w.unread(w.err)}
	}
	m := Mark{w: w, after: w.announced}
	for _, s := range w.shown {
		m.windows = append(m.windows, s)
	}
	return m
}

func (w *Windows) unread(err error) error {
	return fmt.Errorf("the compositor's list of windows cannot be read: %w", err)
}

// Closed waits, for at most within, until the compositor has closed every
// window of the mark: nil once it has, and otherwise how many it still
// shows, or why the list cannot say, which is never a yes. First, one
// round trip with the compositor makes the mark current: a window
// announced before it, after the mark was taken, was in transit as it
// was, and is marked too. A window the app opens once told of the hide
// would be marked as well were it announced before the round trip's end,
// and the hide then unconfirmed; the app's making of a window takes far
// longer than a round trip.
func (m Mark) Closed(within time.Duration) error {
	if m.err != nil {
		return m.err
	}
	w := m.w
	deadline := time.NewTimer(within)
	defer deadline.Stop()
	w.mu.Lock()
	id, done := w.next, make(chan []*window, 1)
	w.next++
	w.syncs[id] = done
	w.mu.Unlock()
	if err := w.send(Display, DisplaySync, Words(id)); err != nil {
		w.fail(err)
		return w.unread(err)
	}
	marked := m.windows
	for waiting := true; waiting; {
		w.mu.Lock()
		err, changed := w.err, w.changed
		w.mu.Unlock()
		if err != nil {
			return w.unread(err)
		}
		select {
		case now := <-done:
			for _, s := range now {
				if s.order > m.after {
					marked = append(marked, s)
				}
			}
			waiting = false
		case <-changed:
		case <-deadline.C:
			return fmt.Errorf("the compositor did not answer a round trip within %v", within)
		}
	}
	for {
		w.mu.Lock()
		err, changed := w.err, w.changed
		open := 0
		for _, s := range marked {
			if !s.closed {
				open++
			}
		}
		w.mu.Unlock()
		switch {
		case err != nil:
			return w.unread(err)
		case open == 0:
			return nil
		}
		select {
		case <-changed:
		case <-deadline.C:
			return fmt.Errorf("the compositor still shows %d of the %d windows shown then after %v", open, len(marked), within)
		}
	}
}

// Close ends the list.
func (w *Windows) Close() error {
	if w.conn == nil {
		return nil
	}
	return w.conn.Close()
}
