// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package idle hears from a Wayland compositor when a seat has had no input
// from a person for a time, whatever a page plays. It asks for
// ext_idle_notifier_v1's get_input_idle_notification (version 2): the
// notification every idle daemon takes, get_idle_notification, is held off
// by any client's idle inhibitor, and a browser takes one for a page that
// plays video with sound.
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
)

// The requests and events it uses, by their opcodes.
const (
	displaySync        = 0
	displayGetRegistry = 1
	displayError       = 0

	registryBind         = 0
	registryGlobal       = 0
	registryGlobalRemove = 1

	callbackDone = 0

	notifierGetInputIdle = 2
	notificationIdled    = 0

	// inputIdleVersion is the notifier's first version with
	// get_input_idle_notification.
	inputIdleVersion = 2
)

const (
	header = 8
	// maxMessage is the most a Wayland message holds.
	maxMessage = 4096
	// answerWithin bounds the compositor's answers while the watch starts.
	answerWithin = 5 * time.Second
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
	ctx, cancel := context.WithTimeout(ctx, answerWithin)
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
	return w.until(accepted, w.removed)
}

// Run calls idled each time the seat has had no input for the time asked,
// once for each stretch without any. It returns when the watch can tell no
// more: the compositor went or refused, its seat or notifier went, or Close.
func (w *Watch) Run(idled func()) error {
	for {
		m, err := w.next()
		if err != nil {
			return err
		}
		if err := w.removed(m); err != nil {
			return err
		}
		if m.object == notification && m.opcode == notificationIdled {
			idled()
		}
	}
}

// Close ends the watch, and Run with it.
func (w *Watch) Close() error { return w.conn.Close() }

func (w *Watch) removed(m message) error {
	if m.object != registry || m.opcode != registryGlobalRemove {
		return nil
	}
	if len(m.body) < 4 {
		return errShort
	}
	if name := wire.Uint32(m.body); name == w.seatName || name == w.notifierName {
		return errors.New("the compositor took away the seat or its idle notifier")
	}
	return nil
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
