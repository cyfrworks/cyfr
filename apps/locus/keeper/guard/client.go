// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package guard

import (
	"errors"
	"fmt"
	"net"
	"net/netip"
	"os"
	"sync"
	"sync/atomic"
	"time"

	"golang.org/x/sys/unix"
)

const (
	dialTimeout = 2 * time.Second
	// replyTimeout bounds one request's answer: the guard script's own bound
	// and a margin.
	replyTimeout = applyTimeout + 5*time.Second
)

// ErrConnectionGone is a clear's answer when the route was made over a
// connection that has ended since: the guard withdrew it then, by its own
// rule, and nothing is asked of a connection that never knew it.
var ErrConnectionGone = errors.New("the route's connection to the guard has ended, and the guard withdrew every route made over it")

// Route names one admitted route by the connection it was made over.
type Route struct{ Conn uint64 }

// Client is a keeper's connection to its island's guard. It dials on first
// use and after the connection before it has ended, and takes a guard's
// answers only once its hello names the keeper's own network namespace.
// Requests are sent one at a time.
//
// A reader holds every connection from its hello to its end, so the end is
// seen as it happens, idle or not: the guard dying, an answer that is not
// one, or the keeper dropping a connection whose answer never came. At that
// end the client calls lost with the connection's number and waits for it
// to return before anything may dial again: the keeper kills there every
// space routed over it, whose route the guard withdraws or has lost with
// its namespace, so no space outlives the guard that held its route.
type Client struct {
	path  string
	netns string
	lost  func(conn uint64)

	mu   sync.Mutex
	link *link
	next uint64
	// live is the connection standing, read without mu by Live.
	live atomic.Pointer[link]
	// answered, when set, is called by the reader after it hands an
	// answer on and before it reads again: a test holds it there.
	answered func()
}

// link is one connection and its reader.
type link struct {
	conn    *net.UnixConn
	number  uint64
	answers chan []byte
	ended   chan struct{}
	// waiting is set while a request awaits its answer; an answer the
	// reader reads while it is not set ends the connection.
	mu      sync.Mutex
	waiting bool
}

// NewClient is a client of the guard serving path, for a keeper in the
// network namespace netns (what /proc/self/ns/net links to), calling lost
// at each connection's end.
func NewClient(path, netns string, lost func(conn uint64)) *Client {
	return &Client{path: path, netns: netns, lost: lost}
}

// Admit asks the guard for a space's route: its reach (ReachIsland, or
// ReachHosts with exactly addrs), its network namespace and its two name
// sockets. It answers the connection the route was made over once the guard
// says admitted, and an error for a refusal, for an answer that is not one,
// and for a connection that ended before the answer; in the last two the
// connection's end has been handled (lost) before Admit returns.
func (c *Client) Admit(spawnID, reach string, addrs []netip.Addr, netns, udp, tcp *os.File) (Route, error) {
	m := Message{Type: TypeAdmit, SpawnID: spawnID, Reach: reach}
	if reach == ReachHosts {
		if len(addrs) == 0 || len(addrs) > MaxAddresses {
			return Route{}, fmt.Errorf("an admit names 1..%d addresses", MaxAddresses)
		}
		m.Addresses = make([]string, len(addrs))
		for i, a := range addrs {
			m.Addresses[i] = a.Unmap().WithZone("").String()
		}
	}
	number, err := c.request(m, unix.UnixRights(int(netns.Fd()), int(udp.Fd()), int(tcp.Fd())))
	return Route{Conn: number}, err
}

// Clear asks the guard to withdraw the route r and answers once it says
// cleared. A route whose connection has ended is not asked for:
// ErrConnectionGone.
func (c *Client) Clear(spawnID string, r Route) error {
	c.mu.Lock()
	current := c.settle()
	c.mu.Unlock()
	if current == nil || current.number != r.Conn {
		return ErrConnectionGone
	}
	number, err := c.request(Message{Type: TypeClear, SpawnID: spawnID}, nil)
	if err == nil && number != r.Conn {
		// A connection ended and another was dialed between the check
		// and the request: the route went with the first.
		return ErrConnectionGone
	}
	return err
}

// request sends one request and reads its answer, answering the number of
// the connection it went over.
func (c *Client) request(m Message, rights []byte) (uint64, error) {
	packet, err := Encode(m)
	if err != nil {
		return 0, err
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	l := c.settle()
	if l == nil {
		if l, err = c.connect(); err != nil {
			return 0, err
		}
	}
	l.mu.Lock()
	l.waiting = true
	l.mu.Unlock()
	_ = l.conn.SetWriteDeadline(time.Now().Add(replyTimeout))
	if _, _, err := l.conn.WriteMsgUnix(packet, rights, nil); err != nil {
		c.end(l)
		return l.number, fmt.Errorf("the guard: sending the %s: %w", m.Type, err)
	}
	var answer []byte
	select {
	case answer = <-l.answers:
	case <-l.ended:
		c.link = nil
		return l.number, fmt.Errorf("the guard's connection ended before it answered the %s of spawn %s", m.Type, m.SpawnID)
	case <-time.After(replyTimeout):
		c.end(l)
		return l.number, fmt.Errorf("the guard did not answer the %s of spawn %s", m.Type, m.SpawnID)
	}
	l.mu.Lock()
	l.waiting = false
	l.mu.Unlock()
	reply, err := ParseAnswer(answer, m.Type, m.SpawnID)
	if err != nil {
		c.end(l)
		return l.number, fmt.Errorf("the guard's answer to the %s of spawn %s: %w", m.Type, m.SpawnID, err)
	}
	if reply.Type == TypeRefused {
		return l.number, fmt.Errorf("the guard refused the %s of spawn %s: %s", m.Type, m.SpawnID, reply.Reason)
	}
	return l.number, nil
}

// settle answers the connection standing, after forgetting one that has
// ended; c.mu is held.
func (c *Client) settle() *link {
	if c.link != nil {
		select {
		case <-c.link.ended:
			c.link = nil
		default:
		}
	}
	return c.link
}

// Live reports whether r's connection is the client's live one at this
// instant: it stands, its reader has not seen it end, and no end or packet
// waits on it unread. It takes no lock a request holds, so it may be asked
// under a lock the connection's end takes (the keeper's).
func (c *Client) Live(r Route) bool {
	l := c.live.Load()
	if l == nil || l.number != r.Conn {
		return false
	}
	select {
	case <-l.ended:
		return false
	default:
	}
	raw, err := l.conn.SyscallConn()
	if err != nil {
		return false
	}
	pending := true
	if cerr := raw.Control(func(fd uintptr) {
		_, _, rerr := unix.Recvfrom(int(fd), make([]byte, 1), unix.MSG_PEEK|unix.MSG_DONTWAIT)
		pending = !errors.Is(rerr, unix.EAGAIN)
	}); cerr != nil {
		return false
	}
	return !pending
}

// end closes l and waits for its reader to have handled the end; c.mu is
// held.
func (c *Client) end(l *link) {
	_ = l.conn.Close()
	<-l.ended
	c.link = nil
}

// connect dials the guard and reads its hello, then starts the reader;
// c.mu is held, and every connection before has ended and been handled.
func (c *Client) connect() (*link, error) {
	conn, err := net.DialTimeout("unixpacket", c.path, dialTimeout)
	if err != nil {
		return nil, fmt.Errorf("the guard: %w", err)
	}
	uc := conn.(*net.UnixConn)
	_ = uc.SetReadDeadline(time.Now().Add(dialTimeout))
	packet, err := readPacket(uc, nil)
	var hello Message
	if err == nil {
		hello, err = Decode(packet)
	}
	switch {
	case err != nil:
		uc.Close()
		return nil, fmt.Errorf("the guard's hello: %w", err)
	case hello.Type != TypeHello || hello.SpawnID != "" || hello.Reason != "":
		uc.Close()
		return nil, errors.New("the guard did not greet")
	case hello.Netns != c.netns:
		uc.Close()
		return nil, fmt.Errorf("the guard judges %s, not this keeper's %s: the service must be recreated behind its guard", hello.Netns, c.netns)
	}
	_ = uc.SetReadDeadline(time.Time{})
	c.next++
	l := &link{conn: uc, number: c.next, answers: make(chan []byte, 1), ended: make(chan struct{})}
	c.link = l
	c.live.Store(l)
	go c.read(l)
	return l, nil
}

// read holds l from its hello to its end, passing each answer to the
// request awaiting it. Any other packet, a read that fails and the guard's
// end of the socket end the connection; lost is called, and only then is
// the end seen by anything that would dial again.
func (c *Client) read(l *link) {
	defer close(l.ended)
	defer c.live.CompareAndSwap(l, nil)
	defer func() {
		if c.lost != nil {
			c.lost(l.number)
		}
	}()
	defer l.conn.Close()
	for {
		packet, err := readPacket(l.conn, nil)
		if err != nil {
			return
		}
		l.mu.Lock()
		waiting := l.waiting
		l.waiting = false
		l.mu.Unlock()
		if !waiting {
			return
		}
		l.answers <- packet
		if c.answered != nil {
			c.answered()
		}
	}
}

// readPacket reads one packet of at most MaxMessageBytes, refusing one the
// kernel cut short, and the descriptors it carried into rights where rights
// is not nil; a packet that carries descriptors where none are taken is
// refused, its descriptors closed.
func readPacket(conn *net.UnixConn, rights *[]int) ([]byte, error) {
	buf := make([]byte, MaxMessageBytes+1)
	oob := make([]byte, unix.CmsgSpace(4*AdmitDescriptors))
	n, oobn, flags, _, err := conn.ReadMsgUnix(buf, oob)
	if err != nil {
		return nil, err
	}
	var fds []int
	if oobn > 0 {
		msgs, perr := unix.ParseSocketControlMessage(oob[:oobn])
		if perr != nil {
			return nil, perr
		}
		for i := range msgs {
			got, perr := unix.ParseUnixRights(&msgs[i])
			if perr == nil {
				fds = append(fds, got...)
			}
		}
	}
	closeAll := func() {
		for _, fd := range fds {
			_ = unix.Close(fd)
		}
	}
	switch {
	case n == 0 && oobn == 0:
		return nil, errors.New("the connection ended")
	case flags&(unix.MSG_TRUNC|unix.MSG_CTRUNC) != 0 || n > MaxMessageBytes:
		closeAll()
		return nil, errors.New("a message longer than the control allows")
	case len(fds) > 0 && rights == nil:
		closeAll()
		return nil, errors.New("descriptors where none are taken")
	}
	if rights != nil {
		*rights = fds
	}
	return buf[:n], nil
}
