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
	"bufio"
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"time"
)

// The objects this client names, in the order it makes them, which Wayland
// requires of a client's ids.
const (
	display uint32 = iota + 1
	registry
	listed
	seat
	notifier
	notification
	accepted
	// alive is the round trip's callback, one at a time: its id is used
	// again once the compositor said it deleted the last.
	alive
)

// The requests and events it uses, by their opcodes.
const (
	displaySync        = 0
	displayGetRegistry = 1
	displayError       = 0
	displayDeleteID    = 1

	registryBind         = 0
	registryGlobal       = 0
	registryGlobalRemove = 1

	callbackDone = 0

	seatCapabilities = 0

	notifierGetInputIdle = 2
	notificationIdled    = 0
	notificationResumed  = 1

	// inputIdleVersion is the notifier's first version with
	// get_input_idle_notification.
	inputIdleVersion = 2
)

const (
	header = 8
	// maxMessage is the most a Wayland message holds.
	maxMessage = 4096

	// CheckEvery is how often a watch is asked to show that it works, and
	// AnswerWithin how long it has to show it: the same for any watch that
	// locks the screen.
	CheckEvery   = 2 * time.Second
	AnswerWithin = 5 * time.Second
)

var wire = binary.NativeEndian

// Watch is one seat's input-idle notification.
type Watch struct {
	conn net.Conn
	r    *bufio.Reader
	// seatName and notifierName are the two globals' names, whose removal
	// ends the watch.
	seatName, notifierName uint32
}

// Socket is the compositor's socket, as a Wayland client finds it.
func Socket() (string, error) {
	name := os.Getenv("WAYLAND_DISPLAY")
	if filepath.IsAbs(name) {
		return name, nil
	}
	dir := os.Getenv("XDG_RUNTIME_DIR")
	if name == "" || dir == "" {
		return "", errors.New("no Wayland compositor is named in WAYLAND_DISPLAY and XDG_RUNTIME_DIR")
	}
	return filepath.Join(dir, name), nil
}

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
	w := &Watch{conn: conn, r: bufio.NewReader(conn)}
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
	if err := w.send(display, displayGetRegistry, words(registry)); err != nil {
		return err
	}
	if err := w.send(display, displaySync, words(listed)); err != nil {
		return err
	}
	var seats, notifiers bool
	var version uint32
	err := w.until(listed, func(m message) error {
		if err := w.place(m); err != nil {
			return err
		}
		if m.object != registry || m.opcode != registryGlobal {
			return nil
		}
		name, iface, v, err := m.global()
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
		{registry, registryBind, bind(w.seatName, "wl_seat", 1, seat)},
		{registry, registryBind, bind(w.notifierName, "ext_idle_notifier_v1", inputIdleVersion, notifier)},
		{notifier, notifierGetInputIdle, words(notification, ms, seat)},
		{display, displaySync, words(accepted)},
	} {
		if err := w.send(request.object, request.opcode, request.body); err != nil {
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
			if err := w.send(display, displaySync, words(alive)); err != nil {
				return err
			}
			asking, due = true, time.Now().Add(AnswerWithin)
		}
		if err := w.conn.SetReadDeadline(due); err != nil {
			return err
		}
		if _, err := w.r.Peek(1); err != nil {
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
		m, err := w.next()
		switch {
		case asking && !time.Now().Before(due):
			return errSilent
		case err != nil:
			return err
		case m.object == alive && m.opcode == callbackDone && len(m.body) == 4 && asking:
		case m.deletes(alive) && asking:
			asking, due = false, time.Now().Add(CheckEvery)
		case m.object == notification && m.opcode == notificationIdled && len(m.body) == 0:
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
func (w *Watch) place(m message) error {
	switch {
	case m.deletes(listed), m.deletes(accepted):
		return nil
	case m.object == registry && m.opcode == registryGlobal:
		_, _, _, err := m.global()
		return err
	case m.object == registry && m.opcode == registryGlobalRemove && len(m.body) == 4:
		if name := wire.Uint32(m.body); name == w.seatName || name == w.notifierName {
			return errors.New("the compositor took away the seat or its idle notifier")
		}
		return nil
	case m.object == seat && m.opcode == seatCapabilities && len(m.body) == 4:
		return nil
	case m.object == notification && len(m.body) == 0 &&
		(m.opcode == notificationIdled || m.opcode == notificationResumed):
		return nil
	}
	return fmt.Errorf("%w (object %d, opcode %d)", errUnplaced, m.object, m.opcode)
}

// deletes is whether m is the display saying it deleted id.
func (m message) deletes(id uint32) bool {
	return m.object == display && m.opcode == displayDeleteID && len(m.body) == 4 && wire.Uint32(m.body) == id
}

// until reads to callback's done, giving each message before it to each.
func (w *Watch) until(callback uint32, each func(message) error) error {
	for {
		m, err := w.next()
		if err != nil {
			return err
		}
		if m.object == callback && m.opcode == callbackDone {
			return nil
		}
		if err := each(m); err != nil {
			return err
		}
	}
}

var errShort = errors.New("the compositor sent a message cut short")

type message struct {
	object, opcode uint32
	body           []byte
}

func (w *Watch) next() (message, error) {
	var head [header]byte
	if _, err := io.ReadFull(w.r, head[:]); err != nil {
		return message{}, fmt.Errorf("the compositor's connection ended: %w", err)
	}
	sized := wire.Uint32(head[4:])
	size := sized >> 16
	if size < header || size > maxMessage {
		return message{}, fmt.Errorf("the compositor sent a message of %d bytes", size)
	}
	m := message{object: wire.Uint32(head[:]), opcode: sized & 0xffff, body: make([]byte, size-header)}
	if _, err := io.ReadFull(w.r, m.body); err != nil {
		return message{}, fmt.Errorf("the compositor's connection ended: %w", err)
	}
	if m.object == display && m.opcode == displayError {
		// The error names an object and a code, then says why.
		if len(m.body) < 8 {
			return message{}, errShort
		}
		why, _, err := text(m.body[8:])
		if err != nil {
			return message{}, err
		}
		return message{}, fmt.Errorf("the compositor refused: %s", why)
	}
	return m, nil
}

func (m message) global() (name uint32, iface string, version uint32, err error) {
	if len(m.body) < 4 {
		return 0, "", 0, errShort
	}
	iface, rest, err := text(m.body[4:])
	if err != nil {
		return 0, "", 0, err
	}
	if len(rest) < 4 {
		return 0, "", 0, errShort
	}
	return wire.Uint32(m.body), iface, wire.Uint32(rest), nil
}

// text reads a Wayland string: its length with the NUL that ends it, then
// its bytes, padded to four.
func text(b []byte) (string, []byte, error) {
	if len(b) < 4 {
		return "", nil, errShort
	}
	n := uint64(wire.Uint32(b))
	padded := (n + 3) &^ 3
	if n == 0 || padded > uint64(len(b)-4) {
		return "", nil, errShort
	}
	return string(b[4 : 4+n-1]), b[4+padded:], nil
}

func (w *Watch) send(object, opcode uint32, body []byte) error {
	_, err := w.conn.Write(append(words(object, uint32(header+len(body))<<16|opcode), body...))
	return err
}

func words(values ...uint32) []byte {
	var b []byte
	for _, v := range values {
		b = wire.AppendUint32(b, v)
	}
	return b
}

// bind is wl_registry.bind's body, whose untyped new id carries its
// interface and version before it.
func bind(name uint32, iface string, version, id uint32) []byte {
	b := append(words(name, uint32(len(iface)+1)), iface...)
	b = append(b, 0)
	for len(b)%4 != 0 {
		b = append(b, 0)
	}
	return append(b, words(version, id)...)
}
