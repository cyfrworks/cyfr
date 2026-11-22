// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package idletest is a compositor as an idle watch meets it, for tests:
// the registry, a seat and ext_idle_notifier_v1 with both its
// notifications, the ordinary one held off while Inhibited and the input
// one not, as the protocol's text and labwc have it.
package idletest

import (
	"bufio"
	"encoding/binary"
	"io"
	"net"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

var wire = binary.NativeEndian

// The names the registry gives its globals.
const (
	SeatName     uint32 = 11
	NotifierName uint32 = 12
)

// NotificationObject is the id a watch's notification has, for Send.
const NotificationObject uint32 = 6

// Asked is a notification a client asked for.
type Asked struct {
	// InputOnly is whether it was get_input_idle_notification.
	InputOnly bool
	After     time.Duration
}

// Compositor is one stand-in compositor.
type Compositor struct {
	// Socket is where it listens.
	Socket string
	// Asked receives each notification asked for.
	Asked chan Asked
	// Synced receives each round trip answered.
	Synced chan struct{}

	options Options
	ln      net.Listener

	mu      sync.Mutex
	clients map[*client]bool
}

// Options are how it differs from labwc with a page playing nothing.
type Options struct {
	// Inhibited is a client holding an idle inhibitor, as a browser does
	// for a page playing a video that a tap or click started.
	Inhibited bool
	// Version is the notifier's; 0 is 2.
	Version uint32
	// NoNotifier leaves the notifier out, NoSeat the seat.
	NoNotifier, NoSeat bool
	// Refusal answers a request for a notification with this error.
	Refusal string
	// Silent answers nothing at all.
	Silent bool
}

type client struct {
	c        net.Conn
	frozen   bool
	write    sync.Mutex
	registry uint32
	bound    map[uint32]string
	notes    []*note
}

type note struct {
	id    uint32
	after time.Duration
	input bool
	timer *time.Timer
	idle  bool
}

// Start is a compositor listening until the test ends.
func Start(t testing.TB, o Options) *Compositor {
	t.Helper()
	// A socket's path has 108 bytes, fewer than a test's own directory may.
	dir, err := os.MkdirTemp("", "wl")
	if err != nil {
		t.Fatal(err)
	}
	if o.Version == 0 {
		o.Version = 2
	}
	c := &Compositor{Socket: filepath.Join(dir, "s"), Asked: make(chan Asked, 8), Synced: make(chan struct{}, 64), options: o, clients: map[*client]bool{}}
	if c.ln, err = net.Listen("unix", c.Socket); err != nil {
		_ = os.RemoveAll(dir)
		t.Fatal(err)
	}
	t.Cleanup(func() {
		c.Stop()
		_ = os.RemoveAll(dir)
	})
	go func() {
		for {
			conn, err := c.ln.Accept()
			if err != nil {
				return
			}
			cl := &client{c: conn, bound: map[uint32]string{}}
			c.mu.Lock()
			c.clients[cl] = true
			c.mu.Unlock()
			go c.serve(cl)
		}
	}()
	return c
}

// Stop ends the compositor, as labwc's own end does.
func (c *Compositor) Stop() {
	_ = c.ln.Close()
	c.mu.Lock()
	defer c.mu.Unlock()
	for cl := range c.clients {
		c.drop(cl)
	}
}

// Input is a person's input: every notification starts its time again.
func (c *Compositor) Input() {
	c.mu.Lock()
	defer c.mu.Unlock()
	for cl := range c.clients {
		for _, n := range cl.notes {
			if n.idle {
				n.idle = false
				cl.send(n.id, 1, nil)
			}
			n.timer.Reset(n.after)
		}
	}
}

// Freeze stops answering, each connection left open, as a compositor
// that hangs does.
func (c *Compositor) Freeze() {
	c.mu.Lock()
	defer c.mu.Unlock()
	for cl := range c.clients {
		cl.frozen = true
	}
}

// Stall begins a message of size bytes, sends its first n and then stops
// answering, as a compositor that hangs as it writes does.
func (c *Compositor) Stall(size, n int) {
	c.mu.Lock()
	defer c.mu.Unlock()
	whole := append(words(NotificationObject, uint32(size)<<16), make([]byte, size-8)...)
	for cl := range c.clients {
		cl.frozen = true
		cl.write.Lock()
		_, _ = cl.c.Write(whole[:n])
		cl.write.Unlock()
	}
}

// Send sends an event of any kind.
func (c *Compositor) Send(object, opcode uint32, body ...uint32) {
	c.mu.Lock()
	defer c.mu.Unlock()
	for cl := range c.clients {
		cl.send(object, opcode, words(body...))
	}
}

// Remove takes the global name away.
func (c *Compositor) Remove(name uint32) {
	c.mu.Lock()
	defer c.mu.Unlock()
	for cl := range c.clients {
		cl.send(cl.registry, 1, words(name))
	}
}

func (c *Compositor) drop(cl *client) {
	_ = cl.c.Close()
	for _, n := range cl.notes {
		n.timer.Stop()
	}
	delete(c.clients, cl)
}

func (c *Compositor) serve(cl *client) {
	defer func() {
		c.mu.Lock()
		c.drop(cl)
		c.mu.Unlock()
	}()
	r := bufio.NewReader(cl.c)
	for {
		var head [8]byte
		if _, err := io.ReadFull(r, head[:]); err != nil {
			return
		}
		object, sized := wire.Uint32(head[:]), wire.Uint32(head[4:])
		if sized>>16 < 8 {
			return
		}
		body := make([]byte, sized>>16-8)
		if _, err := io.ReadFull(r, body); err != nil {
			return
		}
		if c.options.Silent {
			continue
		}
		if !c.answer(cl, object, sized&0xffff, body) {
			return
		}
	}
}

func (c *Compositor) answer(cl *client, object, opcode uint32, body []byte) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	if cl.frozen {
		return true
	}
	switch {
	case object == 1 && opcode == 0 && len(body) == 4: // sync
		id := wire.Uint32(body)
		cl.send(id, 0, words(0))
		cl.send(1, 1, words(id)) // wl_display.delete_id, as the server follows a callback
		select {
		case c.Synced <- struct{}{}:
		default:
		}
	case object == 1 && opcode == 1 && len(body) == 4: // get_registry
		cl.registry = wire.Uint32(body)
		cl.send(cl.registry, 0, global(7, "wl_compositor", 6))
		if !c.options.NoSeat {
			cl.send(cl.registry, 0, global(SeatName, "wl_seat", 9))
		}
		if !c.options.NoNotifier {
			cl.send(cl.registry, 0, global(NotifierName, "ext_idle_notifier_v1", c.options.Version))
		}
	case object == cl.registry && opcode == 0 && len(body) >= 16: // bind
		n := int(wire.Uint32(body[4:]))
		end := 8 + (n+3)&^3
		if n < 1 || end+8 != len(body) {
			return false
		}
		iface := string(body[8 : 8+n-1])
		version := wire.Uint32(body[end:])
		if iface == "ext_idle_notifier_v1" && version > c.options.Version {
			return false
		}
		cl.bound[wire.Uint32(body[end+4:])] = iface
	case cl.bound[object] == "ext_idle_notifier_v1" && (opcode == 1 || opcode == 2) && len(body) == 12:
		n := &note{id: wire.Uint32(body), input: opcode == 2, after: time.Duration(wire.Uint32(body[4:])) * time.Millisecond}
		if cl.bound[wire.Uint32(body[8:])] != "wl_seat" {
			return false
		}
		if c.options.Refusal != "" {
			cl.send(1, 0, append(words(object, 0), text(c.options.Refusal)...))
			return true
		}
		n.timer = time.AfterFunc(n.after, func() {
			c.mu.Lock()
			defer c.mu.Unlock()
			if c.clients[cl] && !n.idle && (n.input || !c.options.Inhibited) {
				n.idle = true
				cl.send(n.id, 0, nil)
			}
		})
		cl.notes = append(cl.notes, n)
		select {
		case c.Asked <- Asked{InputOnly: n.input, After: n.after}:
		default:
		}
	}
	return true
}

func (cl *client) send(object, opcode uint32, body []byte) {
	cl.write.Lock()
	defer cl.write.Unlock()
	_, _ = cl.c.Write(append(words(object, uint32(8+len(body))<<16|opcode), body...))
}

func words(values ...uint32) []byte {
	var b []byte
	for _, v := range values {
		b = wire.AppendUint32(b, v)
	}
	return b
}

func text(s string) []byte {
	b := append(words(uint32(len(s)+1)), s...)
	b = append(b, 0)
	for len(b)%4 != 0 {
		b = append(b, 0)
	}
	return b
}

func global(name uint32, iface string, version uint32) []byte {
	return append(append(words(name), text(iface)...), words(version)...)
}
