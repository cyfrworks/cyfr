// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package guard

import (
	"bufio"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"sync"
	"time"
)

const (
	dialTimeout = 2 * time.Second
	// replyTimeout bounds one request's answer: the guard script's own bound
	// and a margin.
	replyTimeout = applyTimeout + 5*time.Second
)

// Client is a keeper's connection to its island's guard. It dials on first
// use and again after any failure, and takes a guard's answers only once
// its hello names the keeper's own network namespace. Requests are sent one
// at a time.
type Client struct {
	path  string
	netns string

	mu   sync.Mutex
	conn net.Conn
	r    *bufio.Reader
}

// NewClient is a client of the guard serving path, for a keeper in the
// network namespace netns (what /proc/self/ns/net links to).
func NewClient(path, netns string) *Client {
	return &Client{path: path, netns: netns}
}

// Admit has the guard give uid exactly addrs, and no other public address.
func (c *Client) Admit(uid int, addrs []netip.Addr) error {
	if len(addrs) == 0 || len(addrs) > MaxAddresses {
		return fmt.Errorf("an admit names 1..%d addresses", MaxAddresses)
	}
	text := make([]string, len(addrs))
	for i, a := range addrs {
		text[i] = a.Unmap().WithZone("").String()
	}
	return c.request(Message{Type: TypeAdmit, Addresses: text}, uid, TypeAdmitted)
}

// Clear has the guard return uid to the island's rule.
func (c *Client) Clear(uid int) error {
	return c.request(Message{Type: TypeClear}, uid, TypeCleared)
}

func (c *Client) request(m Message, uid int, want string) error {
	if uid < 1 || uint64(uid) > MaxUID {
		return fmt.Errorf("uid %d is out of range", uid)
	}
	u := uint64(uid)
	m.UID = &u
	line, err := Encode(m)
	if err != nil {
		return err
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if err := c.connect(); err != nil {
		return err
	}
	reply, err := c.exchange(line)
	if err != nil {
		c.drop()
		return err
	}
	switch {
	case reply.Type == want && reply.UID != nil && *reply.UID == u:
		return nil
	case reply.Type == TypeRefused:
		return fmt.Errorf("the guard refused the %s of uid %d: %s", m.Type, uid, reply.Reason)
	default:
		c.drop()
		return fmt.Errorf("the guard answered the %s of uid %d with %s", m.Type, uid, reply.Type)
	}
}

// connect dials the guard and reads its hello, unless a connection stands.
func (c *Client) connect() error {
	if c.conn != nil {
		return nil
	}
	conn, err := net.DialTimeout("unix", c.path, dialTimeout)
	if err != nil {
		return fmt.Errorf("the guard: %w", err)
	}
	c.conn, c.r = conn, bufio.NewReaderSize(conn, 4096)
	_ = conn.SetReadDeadline(time.Now().Add(dialTimeout))
	line, err := readLine(c.r)
	var hello Message
	if err == nil {
		hello, err = Decode(line)
	}
	switch {
	case err != nil:
		c.drop()
		return fmt.Errorf("the guard's hello: %w", err)
	case hello.Type != TypeHello:
		c.drop()
		return errors.New("the guard did not greet")
	case hello.Netns != c.netns:
		c.drop()
		return fmt.Errorf("the guard judges %s, not this keeper's %s: the service must be recreated behind its guard", hello.Netns, c.netns)
	}
	return nil
}

func (c *Client) exchange(line []byte) (Message, error) {
	_ = c.conn.SetDeadline(time.Now().Add(replyTimeout))
	if _, err := c.conn.Write(line); err != nil {
		return Message{}, err
	}
	answer, err := readLine(c.r)
	if err != nil {
		return Message{}, err
	}
	return Decode(answer)
}

func (c *Client) drop() {
	if c.conn != nil {
		_ = c.conn.Close()
	}
	c.conn, c.r = nil, nil
}
