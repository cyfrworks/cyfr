// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package wayland

import (
	"context"
	"errors"
	"fmt"
	"net"
	"slices"
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
)

// Windows is the compositor's own list of the windows it shows
// (zwlr_foreign_toplevel_manager_v1), each by the handle it names it by,
// as it opens and closes them, read for as long as the connection lasts:
// the one word on what a person at the screen sees that comes from no
// program showing it. A list that cannot be read, or no longer is, says
// why, and from then on that is all it says: it confirms nothing.
type Windows struct {
	conn *Conn
	// name is the manager's global, whose removal ends the list.
	name uint32

	mu      sync.Mutex
	shown   map[uint32]bool
	handles map[uint32]bool
	err     error
	// changed is closed at each change, and made anew.
	changed chan struct{}
}

// ListWindows reads the list of windows of the compositor a client finds
// (Socket), the ones shown already first, until Close or the connection's
// end. It returns once the compositor has listed them, or has failed to
// within its bound, which the list then says (Shown).
func ListWindows(ctx context.Context) *Windows {
	w := &Windows{shown: map[uint32]bool{}, handles: map[uint32]bool{}, changed: make(chan struct{})}
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
	if err := w.conn.Send(Display, DisplayGetRegistry, Words(windowsRegistry)); err != nil {
		return err
	}
	if err := w.conn.Send(Display, DisplaySync, Words(windowsListed)); err != nil {
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
	if err := w.conn.Send(windowsRegistry, RegistryBind, Bind(w.name, managerName, 1, windowsManager)); err != nil {
		return err
	}
	if err := w.conn.Send(Display, DisplaySync, Words(windowsBound)); err != nil {
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
		if err := w.place(m); err != nil {
			return err
		}
	}
}

func (w *Windows) read() {
	for {
		m, err := w.conn.Next()
		if err == nil {
			err = w.place(m)
		}
		if err != nil {
			w.mu.Lock()
			w.err = err
			w.change()
			w.mu.Unlock()
			_ = w.conn.Close()
			return
		}
	}
}

// place takes in one event: a window opened or closed, nothing for what
// it says of a window or a deletion, and why the list is lost for any
// other.
func (w *Windows) place(m Message) error {
	w.mu.Lock()
	defer w.mu.Unlock()
	switch {
	case m.Object == windowsManager && m.Opcode == managerToplevel && len(m.Body) == 4:
		handle := Wire.Uint32(m.Body)
		w.handles[handle], w.shown[handle] = true, true
		w.change()
		return nil
	case m.Object == windowsManager && m.Opcode == managerFinished:
		return errors.New("the compositor stopped listing its windows")
	case w.handles[m.Object] && m.Opcode == handleClosed:
		delete(w.handles, m.Object)
		delete(w.shown, m.Object)
		w.change()
		return w.conn.Send(m.Object, handleDestroy, nil)
	case w.handles[m.Object] && m.Opcode <= handleLastEvent:
		return nil
	case m.Object == Display && m.Opcode == DisplayDeleteID:
		return nil
	case m.Object == windowsRegistry && m.Opcode == RegistryGlobal:
		_, _, _, err := m.Global()
		return err
	case m.Object == windowsRegistry && m.Opcode == RegistryGlobalRemove && len(m.Body) == 4:
		if Wire.Uint32(m.Body) == w.name {
			return errors.New("the compositor took away its list of windows")
		}
		return nil
	}
	return fmt.Errorf("the compositor sent an event the list of windows cannot place (object %d, opcode %d)", m.Object, m.Opcode)
}

// change wakes whoever waits on the list; the caller holds w.mu.
func (w *Windows) change() {
	close(w.changed)
	w.changed = make(chan struct{})
}

// Shown is the windows shown now, by their handles, or why the list
// cannot say.
func (w *Windows) Shown() ([]uint32, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.err != nil {
		return nil, fmt.Errorf("the compositor's list of windows cannot be read: %w", w.err)
	}
	var shown []uint32
	for h := range w.shown {
		shown = append(shown, h)
	}
	slices.Sort(shown)
	return shown, nil
}

// Closed waits until the compositor has closed every window of handles,
// for at most within: nil once it has, and otherwise how many it still
// shows, or why the list cannot say, which is never a yes.
func (w *Windows) Closed(handles []uint32, within time.Duration) error {
	deadline := time.NewTimer(within)
	defer deadline.Stop()
	for {
		w.mu.Lock()
		err, changed := w.err, w.changed
		open := 0
		for _, h := range handles {
			if w.shown[h] {
				open++
			}
		}
		w.mu.Unlock()
		switch {
		case err != nil:
			return fmt.Errorf("the compositor's list of windows cannot be read: %w", err)
		case open == 0:
			return nil
		}
		select {
		case <-changed:
		case <-deadline.C:
			return fmt.Errorf("the compositor still shows %d of the %d windows shown then after %v", open, len(handles), within)
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
