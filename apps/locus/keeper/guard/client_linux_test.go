// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package guard

import (
	"errors"
	"fmt"
	"net"
	"net/netip"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

// scriptedGuard is a guard the test drives by hand: it greets with netns
// and hands each accepted connection to the test.
type scriptedGuard struct {
	path  string
	conns chan *net.UnixConn
}

func startScripted(t *testing.T, netns string) *scriptedGuard {
	t.Helper()
	g := &scriptedGuard{path: filepath.Join(t.TempDir(), "guard.sock"), conns: make(chan *net.UnixConn, 8)}
	l, err := net.ListenUnix("unixpacket", &net.UnixAddr{Name: g.path, Net: "unixpacket"})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { l.Close() })
	go func() {
		for {
			c, err := l.AcceptUnix()
			if err != nil {
				return
			}
			t.Cleanup(func() { c.Close() })
			hello, _ := Encode(Message{Type: TypeHello, Netns: netns})
			_, _ = c.Write(hello)
			g.conns <- c
		}
	}()
	return g
}

func (g *scriptedGuard) accept(t *testing.T) *net.UnixConn {
	t.Helper()
	select {
	case c := <-g.conns:
		return c
	case <-time.After(10 * time.Second):
		t.Fatal("the keeper did not dial")
		return nil
	}
}

func (g *scriptedGuard) noDial(t *testing.T, within time.Duration) {
	t.Helper()
	select {
	case <-g.conns:
		t.Fatal("the keeper dialled again")
	case <-time.After(within):
	}
}

// request reads one request and the descriptors it came with.
func request(t *testing.T, c *net.UnixConn) (Message, int) {
	t.Helper()
	_ = c.SetReadDeadline(time.Now().Add(10 * time.Second))
	var fds []int
	packet, err := readPacket(c, &fds)
	if err != nil {
		t.Fatal(err)
	}
	m, err := Decode(packet)
	if err != nil {
		t.Fatal(err)
	}
	return m, len(fds)
}

func answer(t *testing.T, c *net.UnixConn, m Message) {
	t.Helper()
	out, _ := Encode(m)
	if _, err := c.Write(out); err != nil {
		t.Fatal(err)
	}
}

// lostRecorder records each connection's end the client reports, and
// holds each report until it is let go when hold is set.
type lostRecorder struct {
	mu    sync.Mutex
	lost  []uint64
	hold  chan struct{}
	ended chan uint64
}

func newLost() *lostRecorder { return &lostRecorder{ended: make(chan uint64, 8)} }

func (l *lostRecorder) report(conn uint64) {
	l.mu.Lock()
	hold := l.hold
	l.mu.Unlock()
	l.ended <- conn
	if hold != nil {
		<-hold
	}
	l.mu.Lock()
	l.lost = append(l.lost, conn)
	l.mu.Unlock()
}

func (l *lostRecorder) wait(t *testing.T) uint64 {
	t.Helper()
	select {
	case c := <-l.ended:
		return c
	case <-time.After(10 * time.Second):
		t.Fatal("the connection's end was not reported")
		return 0
	}
}

// The keeper sends each request of the vectors as they are written, with
// the descriptors they name, and takes their answers.
func TestTheKeeperSendsTheVectors(t *testing.T) {
	v := loadVectors(t)
	g := startScripted(t, "net:[7]")
	c := NewClient(g.path, "net:[7]", nil)
	netns, udp, tcp := descriptors(t)
	type call func() error
	calls := []call{
		func() error { _, err := c.Admit(testSpawn, ReachIsland, nil, netns, udp, tcp); return err },
		func() error {
			_, err := c.Admit(testSpawn, ReachHosts, []netip.Addr{netip.MustParseAddr("1.2.3.4"), netip.MustParseAddr("2606:4700::1111")}, netns, udp, tcp)
			return err
		},
		func() error { _, err := c.AdmitRole(testSpawn, 4200, true, netns, udp, tcp); return err },
		func() error { _, err := c.AdmitRole(testSpawn, 4101, false, netns, udp, tcp); return err },
		func() error { return c.Clear(testSpawn, Route{Conn: 1}) },
		func() error {
			return machine(c.AdmitMachine(testSpawn, 30201, ReachNone, nil, netns, udp, tcp, netlinkSocket(t)))
		},
		func() error {
			return machine(c.AdmitMachine(testSpawn, 30201, ReachIsland, nil, netns, udp, tcp, netlinkSocket(t)))
		},
		func() error {
			return machine(c.AdmitMachine(testSpawn, 30456, ReachHosts, []netip.Addr{netip.MustParseAddr("1.2.3.4")}, netns, udp, tcp, netlinkSocket(t)))
		},
		func() error {
			return c.Change(testSpawn, Route{Conn: 1}, ReachHosts, []netip.Addr{netip.MustParseAddr("1.2.3.4"), netip.MustParseAddr("2606:4700::1111")})
		},
		func() error { return c.Change(testSpawn, Route{Conn: 1}, ReachIsland, nil) },
		func() error { return c.Change(testSpawn, Route{Conn: 1}, ReachNone, nil) },
	}
	if len(calls) != len(v.Requests) {
		t.Fatalf("%d calls for %d requests", len(calls), len(v.Requests))
	}
	done := make(chan error, 1)
	var conn *net.UnixConn
	for i, req := range v.Requests {
		go func() { done <- calls[i]() }()
		if conn == nil {
			conn = g.accept(t)
		}
		got, n := request(t, conn)
		out, _ := Encode(got)
		if !sameJSON(t, out, req.Message) || n != req.Descriptors {
			t.Fatalf("request %d sent as %s with %d descriptors, want %s with %d", i, out, n, req.Message, req.Descriptors)
		}
		reply := Message{Type: TypeAdmitted, SpawnID: got.SpawnID}
		switch {
		case got.Type == TypeClear:
			reply.Type = TypeCleared
		case got.Type == TypeChange:
			reply.Type = TypeChanged
		case got.MachineUID != nil:
			reply.Inner, reply.Gateway = "10.213.0.2", "10.213.0.1"
		}
		answer(t, conn, reply)
		if err := <-done; err != nil {
			t.Fatalf("request %d: %v", i, err)
		}
	}
}

// machine checks an admitted machine's two addresses, the slot 0 pair.
func machine(m Machine, err error) error {
	if err != nil {
		return err
	}
	if m.Inner != netip.MustParseAddr("10.213.0.2") || m.Gateway != netip.MustParseAddr("10.213.0.1") {
		return fmt.Errorf("the machine's addresses are %s and %s", m.Inner, m.Gateway)
	}
	return nil
}

// A machine's admit answered without its addresses, or a space's with
// them, ends the connection and is refused: the keeper boots no guest it
// cannot address, and takes no word it did not ask for.
func TestAnAdmitAnsweredWithTheWrongAddressesIsRefused(t *testing.T) {
	g := startScripted(t, "net:[7]")
	c := NewClient(g.path, "net:[7]", nil)
	netns, udp, tcp := descriptors(t)
	done := make(chan error, 1)
	go func() {
		_, err := c.AdmitMachine(testSpawn, 30201, ReachIsland, nil, netns, udp, tcp, netlinkSocket(t))
		done <- err
	}()
	conn := g.accept(t)
	request(t, conn)
	answer(t, conn, Message{Type: TypeAdmitted, SpawnID: testSpawn})
	if err := <-done; err == nil {
		t.Fatal("a machine admitted without its addresses was taken")
	}
	go func() { _, err := c.Admit(testSpawn, ReachIsland, nil, netns, udp, tcp); done <- err }()
	conn = g.accept(t)
	request(t, conn)
	answer(t, conn, Message{Type: TypeAdmitted, SpawnID: testSpawn, Inner: "10.213.0.2", Gateway: "10.213.0.1"})
	if err := <-done; err == nil {
		t.Fatal("a space admitted with a machine's addresses was taken")
	}
}

// A connection that ends is reported before anything dials again, and an
// admit whose answer never came is refused, never counted admitted.
func TestAConnectionsEndIsHandledBeforeAnyRedial(t *testing.T) {
	g := startScripted(t, "net:[7]")
	lost := newLost()
	c := NewClient(g.path, "net:[7]", lost.report)
	netns, udp, tcp := descriptors(t)
	done := make(chan error, 1)
	go func() { _, err := c.Admit(testSpawn, ReachIsland, nil, netns, udp, tcp); done <- err }()
	first := g.accept(t)
	request(t, first)
	answer(t, first, Message{Type: TypeAdmitted, SpawnID: testSpawn})
	if err := <-done; err != nil {
		t.Fatal(err)
	}

	lost.mu.Lock()
	lost.hold = make(chan struct{})
	lost.mu.Unlock()
	first.Close()
	if n := lost.wait(t); n != 1 {
		t.Fatalf("connection %d reported, want 1", n)
	}
	go func() {
		_, err := c.Admit("ffeeddccbbaa99887766554433221100", ReachIsland, nil, netns, udp, tcp)
		done <- err
	}()
	g.noDial(t, 300*time.Millisecond)
	close(lost.hold)
	if err := <-done; err == nil {
		t.Fatal("an admit over the ended connection was counted admitted")
	}

	go func() {
		r, err := c.Admit("ffeeddccbbaa99887766554433221100", ReachIsland, nil, netns, udp, tcp)
		if err == nil && r.Conn != 2 {
			err = errors.New("not made over the second connection")
		}
		done <- err
	}()
	second := g.accept(t)
	request(t, second)
	answer(t, second, Message{Type: TypeAdmitted, SpawnID: "ffeeddccbbaa99887766554433221100"})
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}

// An admit whose connection ends before its answer is refused once the end
// has been reported; a clear of a route of an ended connection asks
// nothing of the guard.
func TestAnAdmitWhoseConnectionEndsIsRefusedAfterTheEndIsHandled(t *testing.T) {
	g := startScripted(t, "net:[7]")
	lost := newLost()
	c := NewClient(g.path, "net:[7]", lost.report)
	netns, udp, tcp := descriptors(t)
	done := make(chan error, 1)
	go func() { _, err := c.Admit(testSpawn, ReachIsland, nil, netns, udp, tcp); done <- err }()
	conn := g.accept(t)
	request(t, conn)
	conn.Close()
	err := <-done
	lost.mu.Lock()
	reported := append([]uint64(nil), lost.lost...)
	lost.mu.Unlock()
	if err == nil || len(reported) != 1 || reported[0] != 1 {
		t.Fatalf("the admit answered %v with ends %v reported, want a refusal after connection 1's end", err, reported)
	}
	if err := c.Clear(testSpawn, Route{Conn: 1}); !errors.Is(err, ErrConnectionGone) {
		t.Fatalf("a clear of an ended connection's route: %v", err)
	}
	g.noDial(t, 200*time.Millisecond)
}

// A packet the guard sends unasked, and an answer that is not one, end the
// connection, and the end is reported.
func TestAnAnswerNotAskedForEndsTheConnection(t *testing.T) {
	g := startScripted(t, "net:[7]")
	lost := newLost()
	c := NewClient(g.path, "net:[7]", lost.report)
	netns, udp, tcp := descriptors(t)
	done := make(chan error, 1)
	go func() { _, err := c.Admit(testSpawn, ReachIsland, nil, netns, udp, tcp); done <- err }()
	conn := g.accept(t)
	request(t, conn)
	answer(t, conn, Message{Type: TypeAdmitted, SpawnID: testSpawn})
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	answer(t, conn, Message{Type: TypeAdmitted, SpawnID: testSpawn})
	if n := lost.wait(t); n != 1 {
		t.Fatalf("connection %d reported", n)
	}
	// The end is reported before it is seen (Client.read): a clear is
	// asked once it is.
	settled(t, c)

	if err := c.Clear(testSpawn, Route{Conn: 1}); !errors.Is(err, ErrConnectionGone) {
		t.Fatalf("a clear of an ended connection's route: %v", err)
	}
	go func() { _, err := c.Admit(testSpawn, ReachIsland, nil, netns, udp, tcp); done <- err }()
	conn = g.accept(t)
	request(t, conn)
	answer(t, conn, Message{Type: TypeCleared, SpawnID: testSpawn})
	if err := <-done; err == nil {
		t.Fatal("a cleared answering an admit was taken")
	}
	if n := lost.wait(t); n != 2 {
		t.Fatalf("connection %d reported, want 2", n)
	}
}

// A guard whose hello names another namespace is no guard of this keeper.
func TestAGuardOfAnotherNamespaceIsRefused(t *testing.T) {
	g := startScripted(t, "net:[8]")
	c := NewClient(g.path, "net:[7]", nil)
	netns, udp, tcp := descriptors(t)
	if _, err := c.Admit(testSpawn, ReachIsland, nil, netns, udp, tcp); err == nil {
		t.Fatal("a guard of another namespace admitted")
	}
	if _, err := NewClient(filepath.Join(t.TempDir(), "none.sock"), "net:[7]", nil).Admit(testSpawn, ReachIsland, nil, netns, udp, tcp); err == nil {
		t.Fatal("no guard admitted")
	}
}

// An admitted the reader handed on just before the connection's end is not
// a live route: Live, asked before the reader reads the end, sees the end
// waiting unread.
func TestAnAdmittedJustBeforeTheEndIsNotLive(t *testing.T) {
	g := startScripted(t, "net:[7]")
	c := NewClient(g.path, "net:[7]", nil)
	hold := make(chan struct{})
	c.answered = func() { <-hold }
	netns, udp, tcp := descriptors(t)
	type result struct {
		r   Route
		err error
	}
	done := make(chan result, 1)
	go func() { r, err := c.Admit(testSpawn, ReachIsland, nil, netns, udp, tcp); done <- result{r, err} }()
	conn := g.accept(t)
	request(t, conn)
	answer(t, conn, Message{Type: TypeAdmitted, SpawnID: testSpawn})
	got := <-done
	if got.err != nil {
		t.Fatal(got.err)
	}
	if !c.Live(got.r) {
		t.Fatal("a route of a standing connection is not live")
	}
	conn.Close()
	deadline := time.Now().Add(5 * time.Second)
	for c.Live(got.r) && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond) // sleep-ok: a bounded poll for the peer's end to arrive
	}
	if c.Live(got.r) {
		t.Fatal("an admitted whose connection ended, its reader held before the end, is live")
	}
	close(hold)
}

// settled waits until c holds no connection: the one it held has ended and
// its end has been handled.
func settled(t *testing.T, c *Client) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for {
		c.mu.Lock()
		l := c.settle()
		c.mu.Unlock()
		if l == nil {
			return
		}
		if time.Now().After(deadline) {
			t.Fatal("the connection's end was never seen")
		}
		time.Sleep(time.Millisecond) // sleep-ok: polls the end the reader marks, within a bound
	}
}

// A change refused with its route withdrawn is ErrRouteWithdrawn, the route
// gone; any other refusal leaves the old reach, and is not.
func TestAChangeRefusedWithItsRouteWithdrawnIsToldApart(t *testing.T) {
	g := startScripted(t, "net:[7]")
	c := NewClient(g.path, "net:[7]", nil)
	netns, udp, tcp := descriptors(t)
	admitted := make(chan Machine, 1)
	go func() {
		m, _ := c.AdmitMachine(testSpawn, 30201, ReachNone, nil, netns, udp, tcp, netlinkSocket(t))
		admitted <- m
	}()
	conn := g.accept(t)
	request(t, conn)
	answer(t, conn, Message{Type: TypeAdmitted, SpawnID: testSpawn, Inner: "10.213.0.2", Gateway: "10.213.0.1"})
	m := <-admitted
	done := make(chan error, 1)
	for _, refusal := range []Message{
		{Type: TypeRefused, SpawnID: testSpawn, Reason: "the old reach stands"},
		{Type: TypeRefused, SpawnID: testSpawn, Reason: "withdrawn", Withdrawn: true},
	} {
		go func() { done <- c.Change(testSpawn, m.Route, ReachIsland, nil) }()
		request(t, conn)
		answer(t, conn, refusal)
		err := <-done
		if err == nil || refusal.Withdrawn != errors.Is(err, ErrRouteWithdrawn) {
			t.Fatalf("a change refused as %+v returned %v", refusal, err)
		}
	}
}
