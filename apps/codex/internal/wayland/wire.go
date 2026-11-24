// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package wayland is the Wayland wire as this module's clients speak it to
// the compositor of the screen they run on (internal/idle's watch, the
// list of windows here): each message framed by its object, opcode and
// size, the protocol's strings, a registry's binds, and the compositor's
// socket as a client finds it. A display error ends the reading of a
// connection with the compositor's reason.
package wayland

import (
	"bufio"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
)

// The display's object, which every client has from the start, and the
// requests and events of the core protocol a client of this module uses,
// by their opcodes.
const (
	Display uint32 = 1

	DisplaySync        = 0
	DisplayGetRegistry = 1
	DisplayError       = 0
	DisplayDeleteID    = 1

	RegistryBind         = 0
	RegistryGlobal       = 0
	RegistryGlobalRemove = 1

	CallbackDone = 0
)

const (
	header = 8
	// maxMessage is the most a Wayland message holds.
	maxMessage = 4096
)

// Wire is the byte order of every word on the wire: the machine's own.
var Wire = binary.NativeEndian

// ErrShort is a message whose body is shorter than what it says it holds.
var ErrShort = errors.New("the compositor sent a message cut short")

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

// Conn is one connection to the compositor.
type Conn struct {
	net.Conn
	r *bufio.Reader
}

// NewConn speaks the wire over c.
func NewConn(c net.Conn) *Conn { return &Conn{Conn: c, r: bufio.NewReader(c)} }

// Peek waits for the next message's first byte without reading it.
func (c *Conn) Peek() error {
	_, err := c.r.Peek(1)
	return err
}

// Message is one event the compositor sent.
type Message struct {
	Object, Opcode uint32
	Body           []byte
}

// Next reads the next event; a display error is an error saying why.
func (c *Conn) Next() (Message, error) {
	var head [header]byte
	if _, err := io.ReadFull(c.r, head[:]); err != nil {
		return Message{}, fmt.Errorf("the compositor's connection ended: %w", err)
	}
	sized := Wire.Uint32(head[4:])
	size := sized >> 16
	if size < header || size > maxMessage {
		return Message{}, fmt.Errorf("the compositor sent a message of %d bytes", size)
	}
	m := Message{Object: Wire.Uint32(head[:]), Opcode: sized & 0xffff, Body: make([]byte, size-header)}
	if _, err := io.ReadFull(c.r, m.Body); err != nil {
		return Message{}, fmt.Errorf("the compositor's connection ended: %w", err)
	}
	if m.Object == Display && m.Opcode == DisplayError {
		// The error names an object and a code, then says why.
		if len(m.Body) < 8 {
			return Message{}, ErrShort
		}
		why, _, err := Text(m.Body[8:])
		if err != nil {
			return Message{}, err
		}
		return Message{}, fmt.Errorf("the compositor refused: %s", why)
	}
	return m, nil
}

// Send sends a request to object.
func (c *Conn) Send(object, opcode uint32, body []byte) error {
	_, err := c.Write(append(Words(object, uint32(header+len(body))<<16|opcode), body...))
	return err
}

// Deletes is whether m is the display saying it deleted id.
func (m Message) Deletes(id uint32) bool {
	return m.Object == Display && m.Opcode == DisplayDeleteID && len(m.Body) == 4 && Wire.Uint32(m.Body) == id
}

// Global reads a registry's global event: the global's name, its
// interface and its version.
func (m Message) Global() (name uint32, iface string, version uint32, err error) {
	if len(m.Body) < 4 {
		return 0, "", 0, ErrShort
	}
	iface, rest, err := Text(m.Body[4:])
	if err != nil {
		return 0, "", 0, err
	}
	if len(rest) < 4 {
		return 0, "", 0, ErrShort
	}
	return Wire.Uint32(m.Body), iface, Wire.Uint32(rest), nil
}

// Text reads a Wayland string: its length with the NUL that ends it, then
// its bytes, padded to four; and what follows it.
func Text(b []byte) (string, []byte, error) {
	if len(b) < 4 {
		return "", nil, ErrShort
	}
	n := uint64(Wire.Uint32(b))
	padded := (n + 3) &^ 3
	if n == 0 || padded > uint64(len(b)-4) {
		return "", nil, ErrShort
	}
	return string(b[4 : 4+n-1]), b[4+padded:], nil
}

// Words is values on the wire.
func Words(values ...uint32) []byte {
	var b []byte
	for _, v := range values {
		b = Wire.AppendUint32(b, v)
	}
	return b
}

// Bind is wl_registry.bind's body, whose untyped new id carries its
// interface and version before it.
func Bind(name uint32, iface string, version, id uint32) []byte {
	b := append(Words(name, uint32(len(iface)+1)), iface...)
	b = append(b, 0)
	for len(b)%4 != 0 {
		b = append(b, 0)
	}
	return append(b, Words(version, id)...)
}
