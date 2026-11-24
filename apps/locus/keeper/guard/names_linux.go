// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package guard

import (
	"io"
	"net"
	"os"
	"sync"
	"sync/atomic"
	"time"
)

// A routed space's names. Its two sockets are bound at 127.0.0.11:53 in
// its own namespace, where its resolver configuration points, so its
// queries never leave it: the guard reads them there and asks the island's
// resolver, Docker's, in the guard's own namespace, and writes each answer
// back. A space that has no such sockets, a runner, has no resolver at all.

const (
	// islandResolver is Docker's resolver in the guard's namespace.
	islandResolver = "127.0.0.11:53"
	// maxQueries bounds the UDP queries of one route being answered at
	// once; a query past it is dropped, as a busy resolver's would be.
	maxQueries = 32
	// maxStreams bounds one route's TCP queries at once.
	maxStreams = 4
	// queryTimeout bounds one UDP query's answer from the island's
	// resolver, and streamTimeout one TCP query's whole exchange.
	queryTimeout  = 5 * time.Second
	streamTimeout = 15 * time.Second
	// maxQueryBytes is the largest DNS message over UDP either way, as
	// EDNS answers are sized; a larger answer comes truncated, and the
	// space asks again over TCP.
	maxQueryBytes = 4096
)

// names answers one route's queries until stopped.
type names struct {
	udp  net.PacketConn
	tcp  net.Listener
	wg   sync.WaitGroup
	once sync.Once
	// open holds every connection being answered, which stop closes.
	mu     sync.Mutex
	open   map[io.Closer]bool
	closed bool
	// answered counts the queries answered, which the route's withdrawal
	// logs: how many, never which.
	answered atomic.Uint64
}

// hold records c as being answered, or closes it where stop came first.
func (n *names) hold(c io.Closer) bool {
	n.mu.Lock()
	defer n.mu.Unlock()
	if n.closed {
		_ = c.Close()
		return false
	}
	n.open[c] = true
	return true
}

func (n *names) release(c io.Closer) {
	n.mu.Lock()
	delete(n.open, c)
	n.mu.Unlock()
	_ = c.Close()
}

// serveNames starts answering the queries a space sends to its sockets,
// asking upstream. Each socket is the guard's to close.
func serveNames(udp, tcp *os.File, upstream string) (*names, error) {
	pc, err := net.FilePacketConn(udp)
	if err != nil {
		return nil, err
	}
	ln, err := net.FileListener(tcp)
	if err != nil {
		pc.Close()
		return nil, err
	}
	n := &names{udp: pc, tcp: ln, open: map[io.Closer]bool{}}
	n.wg.Add(2)
	go n.datagrams(upstream)
	go n.streams(upstream)
	return n, nil
}

// stop closes the route's sockets and waits for every query being answered.
func (n *names) stop() {
	n.once.Do(func() {
		_ = n.udp.Close()
		_ = n.tcp.Close()
		n.mu.Lock()
		n.closed = true
		for c := range n.open {
			_ = c.Close()
		}
		n.mu.Unlock()
	})
	n.wg.Wait()
}

func (n *names) datagrams(upstream string) {
	defer n.wg.Done()
	busy := make(chan struct{}, maxQueries)
	for {
		buf := make([]byte, maxQueryBytes)
		size, from, err := n.udp.ReadFrom(buf)
		if err != nil {
			return
		}
		select {
		case busy <- struct{}{}:
		default:
			continue
		}
		n.wg.Add(1)
		go func(query []byte) {
			defer n.wg.Done()
			defer func() { <-busy }()
			up, err := net.DialTimeout("udp", upstream, queryTimeout)
			if err != nil || !n.hold(up) {
				return
			}
			defer n.release(up)
			_ = up.SetDeadline(time.Now().Add(queryTimeout))
			if _, err := up.Write(query); err != nil {
				return
			}
			answer := make([]byte, maxQueryBytes)
			size, err := up.Read(answer)
			if err != nil {
				return
			}
			if _, err := n.udp.WriteTo(answer[:size], from); err == nil {
				n.answered.Add(1)
			}
		}(buf[:size])
	}
}

func (n *names) streams(upstream string) {
	defer n.wg.Done()
	busy := make(chan struct{}, maxStreams)
	for {
		c, err := n.tcp.Accept()
		if err != nil {
			return
		}
		select {
		case busy <- struct{}{}:
		default:
			c.Close()
			continue
		}
		n.wg.Add(1)
		go func() {
			defer n.wg.Done()
			defer func() { <-busy }()
			if !n.hold(c) {
				return
			}
			defer n.release(c)
			deadline := time.Now().Add(streamTimeout)
			_ = c.SetDeadline(deadline)
			up, err := net.DialTimeout("tcp", upstream, queryTimeout)
			if err != nil || !n.hold(up) {
				return
			}
			defer n.release(up)
			_ = up.SetDeadline(deadline)
			done := make(chan struct{})
			go func() {
				_, _ = io.Copy(up, c)
				if tc, ok := up.(*net.TCPConn); ok {
					_ = tc.CloseWrite()
				}
				close(done)
			}()
			if copied, _ := io.Copy(c, up); copied > 0 {
				n.answered.Add(1)
			}
			_ = c.Close()
			<-done
		}()
	}
}
