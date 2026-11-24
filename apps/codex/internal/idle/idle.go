// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package idle hears from a Wayland compositor when a seat has had no input
// from a person for a time, whatever a page plays. It asks for
// ext_idle_notifier_v1's get_input_idle_notification (version 2): the
// notification every idle daemon takes, get_idle_notification, is held off
// by any client's idle inhibitor, and a browser takes one for a page that
// plays a video a tap or click started, with sound or without.
//
// A watch is known to work, never assumed to: it makes a round trip with
// the compositor every CheckEvery, which a person's continued input, met
// with silence, does not disturb, and it is lost at a round trip or a
// message not complete within AnswerWithin, each by its own deadline, and
// at any event it cannot place.
package idle

import (
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"time"

	"github.com/cyfr/codex/internal/wayland"
)

// The objects this client names, in the order it makes them, which Wayland
// requires of a client's ids: the display's first, then each the next.
const (
	display         = wayland.Display
	registry uint32 = iota + 1
	listed
	seat
	notifier
	notification
	accepted
	// alive is the round trip's callback, one at a time: its id is used
	// again once the compositor said it deleted the last.
	alive
)

// The requests and events it uses beside the core protocol's
// (internal/wayland), by their opcodes.
const (
	seatCapabilities = 0

	notifierGetInputIdle = 2
	notificationIdled    = 0
	notificationResumed  = 1

	// inputIdleVersion is the notifier's first version with
	// get_input_idle_notification.
	inputIdleVersion = 2
)

const (
	// CheckEvery is how often a watch is asked to show that it works, and
	// AnswerWithin how long it has to show it: the same for any watch that
	// locks the screen.
	CheckEvery   = 2 * time.Second
	AnswerWithin = 5 * time.Second
)

// Watch is one seat's input-idle notification.
type Watch struct {
	conn *wayland.Conn
	// seatName and notifierName are the two globals' names, whose removal
	// ends the watch.
	seatName, notifierName uint32
}

// Socket is the compositor's socket, as a Wayland client finds it.
func Socket() (string, error) { return wayland.Socket() }

// Start asks the compositor at socket to say when its seat has had no input
// for after, and returns once it took the request. A compositor that
// cannot say it of input alone is refused: there is no falling back to the
// notification a page can hold off.
func Start(ctx context.Context, socket string, after time.Duration) (*Watch, error) {
	ctx, cancel := context.WithTimeout(ctx, AnswerWithin)
	defer cancel()
	conn, err := (&net.Dialer{}).DialContext(ctx, "unix", socket)
	if err != nil {
		return nil, err
	}
	stop := context.AfterFunc(ctx, func() { _ = conn.Close() })
	w := &Watch{conn: wayland.NewConn(conn)}
	err = w.ask(after)
	if !stop() {
		err = errors.Join(err, ctx.Err())
	}
	if err != nil {
		_ = conn.Close()
		return nil, err
	}
	return w, nil
}

func (w *Watch) ask(after time.Duration) error {
	if err := w.conn.Send(display, wayland.DisplayGetRegistry, wayland.Words(registry)); err != nil {
		return err
	}
	if err := w.conn.Send(display, wayland.DisplaySync, wayland.Words(listed)); err != nil {
		return err
	}
	var seats, notifiers bool
	var version uint32
	err := w.until(listed, func(m wayland.Message) error {
		if err := w.place(m); err != nil {
			return err
		}
		if m.Object != registry || m.Opcode != wayland.RegistryGlobal {
			return nil
		}
		name, iface, v, err := m.Global()
		if err != nil {
			return err
		}
		switch {
		case iface == "wl_seat" && !seats:
			seats, w.seatName = true, name
		case iface == "ext_idle_notifier_v1" && !notifiers:
			notifiers, w.notifierName, version = true, name, v
		}
		return nil
	})
	switch {
	case err != nil:
		return err
	case !seats:
		return errors.New("the compositor has no seat")
	case !notifiers || version < inputIdleVersion:
		return errors.New("the compositor cannot tell input from a page holding it awake (ext_idle_notifier_v1 version 2)")
	}
	ms := uint32(after.Milliseconds())
	for _, request := range []struct {
		object, opcode uint32
		body           []byte
	}{
		{registry, wayland.RegistryBind, wayland.Bind(w.seatName, "wl_seat", 1, seat)},
		{registry, wayland.RegistryBind, wayland.Bind(w.notifierName, "ext_idle_notifier_v1", inputIdleVersion, notifier)},
		{notifier, notifierGetInputIdle, wayland.Words(notification, ms, seat)},
		{display, wayland.DisplaySync, wayland.Words(accepted)},
	} {
		if err := w.conn.Send(request.object, request.opcode, request.body); err != nil {
			return err
		}
	}
	return w.until(accepted, w.place)
}

var (
	errSilent   = fmt.Errorf("the compositor did not answer within %v", AnswerWithin)
	errUnplaced = errors.New("the compositor sent an event the watch cannot place")
)

// Run calls idled each time the seat has had no input for the time asked,
// once for each stretch without any. It returns when the watch is not
// known to work: the compositor went, refused, stalled or sent what cannot
// be placed, its seat or notifier went, or Close. The time idled takes is
// not the compositor's to answer in.
func (w *Watch) Run(idled func()) error {
	asking := false
	due := time.Now().Add(CheckEvery)
	for {
		if !time.Now().Before(due) {
			if asking {
				return errSilent
			}
			if err := w.conn.SetWriteDeadline(time.Now().Add(AnswerWithin)); err != nil {
				return err
			}
			if err := w.conn.Send(display, wayland.DisplaySync, wayland.Words(alive)); err != nil {
				return err
			}
			asking, due = true, time.Now().Add(AnswerWithin)
		}
		if err := w.conn.SetReadDeadline(due); err != nil {
			return err
		}
		if err := w.conn.Peek(); err != nil {
			if errors.Is(err, os.ErrDeadlineExceeded) {
				continue
			}
			return fmt.Errorf("the compositor's connection ended: %w", err)
		}
		// A message begun has a bound of its own beside the round trip's,
		// whose deadline it never moves.
		by := time.Now().Add(AnswerWithin)
		if asking && due.Before(by) {
			by = due
		}
		if err := w.conn.SetReadDeadline(by); err != nil {
			return err
		}
		m, err := w.conn.Next()
		switch {
		case asking && !time.Now().Before(due):
			return errSilent
		case err != nil:
			return err
		case m.Object == alive && m.Opcode == wayland.CallbackDone && len(m.Body) == 4 && asking:
		case m.Deletes(alive) && asking:
			asking, due = false, time.Now().Add(CheckEvery)
		case m.Object == notification && m.Opcode == notificationIdled && len(m.Body) == 0:
			began := time.Now()
			idled()
			if asking {
				due = due.Add(time.Since(began))
			}
		default:
			if err := w.place(m); err != nil {
				return err
			}
		}
	}
}

// Close ends the watch, and Run with it.
func (w *Watch) Close() error { return w.conn.Close() }

// place is nil for an event with nothing to say to the watch, and why the
// watch is lost for any other: it is every event but the ones its reader
// acts on.
func (w *Watch) place(m wayland.Message) error {
	switch {
	case m.Deletes(listed), m.Deletes(accepted):
		return nil
	case m.Object == registry && m.Opcode == wayland.RegistryGlobal:
		_, _, _, err := m.Global()
		return err
	case m.Object == registry && m.Opcode == wayland.RegistryGlobalRemove && len(m.Body) == 4:
		if name := wayland.Wire.Uint32(m.Body); name == w.seatName || name == w.notifierName {
			return errors.New("the compositor took away the seat or its idle notifier")
		}
		return nil
	case m.Object == seat && m.Opcode == seatCapabilities && len(m.Body) == 4:
		return nil
	case m.Object == notification && len(m.Body) == 0 &&
		(m.Opcode == notificationIdled || m.Opcode == notificationResumed):
		return nil
	}
	return fmt.Errorf("%w (object %d, opcode %d)", errUnplaced, m.Object, m.Opcode)
}

// until reads to callback's done, giving each message before it to each.
func (w *Watch) until(callback uint32, each func(wayland.Message) error) error {
	for {
		m, err := w.conn.Next()
		if err != nil {
			return err
		}
		if m.Object == callback && m.Opcode == wayland.CallbackDone {
			return nil
		}
		if err := each(m); err != nil {
			return err
		}
	}
}
