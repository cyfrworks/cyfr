// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package main

import (
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"sync"
	"time"

	"github.com/cyfr/locus/keeper/internal/frame"
	"github.com/cyfr/locus/keeper/internal/protocol"
	"github.com/cyfr/locus/keeper/internal/vm"
	"golang.org/x/sys/unix"
)

// pairWait bounds how long an attach connection waits for its other half:
// the host's for a spawn's relay, or a spawn relay's for the host's.
var pairWait = 30 * time.Second

// maxUnmatched bounds the attach connections, the host's and the keeper's
// relays' together, that the relay holds before each is joined to its
// other half: one more is refused at once, so a peer that keeps connecting
// holds at most this many descriptors, goroutines and timers.
const maxUnmatched = 64

// relayMain is the guest keeper's one role, in the role's own space, on
// its channel at file descriptor 3. It makes no vsock socket, which the
// keeper's policy refuses every process under the keeper: the guest's first
// process hands it the control and attach ports' listeners on
// vm.GuestHandoffPath, and vsock is not a network namespace's, so the
// role's space, routed by the guest's guard to nothing, accepts on them.
// It listens before anything can be spawned: on the attach socket for the
// keeper's relays, and on vsock for the host. The host's first control
// connection gets the Hello and then the keeper's channel; each attach
// connection of the host's is joined to the spawn relay that presented the
// same token. It returns when the control connection or the keeper's
// channel ends, and the keeper starts the role again.
func relayMain() int {
	// The keeper's channel is a socket: as a net.Conn its writing side ends
	// apart (CloseWrite), which the keeper reads as its client's end, even
	// while this side still waits on the keeper's.
	keeper, err := net.FileConn(os.NewFile(3, "keeper"))
	if err != nil {
		logf("relay: the keeper's channel on fd 3: %v", err)
		return 1
	}
	// The keeper names the role's run folder, where its relays reach the
	// attach socket: it must be the one the host names in each spawn.
	if dir := os.Getenv(protocol.RunDirEnv); dir != vm.GuestRunDir {
		logf("relay: the role's run folder is %q, not %s", dir, vm.GuestRunDir)
		return 1
	}
	raw, err := os.ReadFile("/proc/sys/kernel/random/boot_id")
	if err != nil {
		logf("relay: %v", err)
		return 1
	}
	hello, err := vm.NewHello(string(raw))
	if err != nil {
		logf("relay: %v", err)
		return 1
	}
	_ = os.Remove(vm.GuestAttachPath)
	attach, err := net.Listen("unix", vm.GuestAttachPath)
	if err != nil {
		logf("relay: %v", err)
		return 1
	}
	control, hostAttach, err := takeListeners()
	if err != nil {
		logf("relay: the vsock listeners: %v", err)
		return 1
	}
	p := &pairs{waiting: map[string]*half{}}
	go acceptAttach(attach, p)
	go acceptHostAttach(hostAttach, p)

	conn, err := acceptHost(control)
	if err != nil {
		logf("relay: the host's control connection: %v", err)
		return 1
	}
	_ = unix.Close(control)
	line, _ := jsonLine(hello)
	if _, err := conn.Write(line); err != nil {
		logf("relay: writing the hello: %v", err)
		return 1
	}
	join(conn, keeper)
	return 0
}

// takeListeners takes the control and attach ports' listeners from the
// guest's first process.
func takeListeners() (control, attach int, err error) {
	conn, err := net.DialUnix("unix", nil, &net.UnixAddr{Name: vm.GuestHandoffPath, Net: "unix"})
	if err != nil {
		return -1, -1, err
	}
	defer conn.Close()
	_ = conn.SetReadDeadline(time.Now().Add(pairWait))
	oob := make([]byte, unix.CmsgSpace(2*4))
	_, oobn, _, _, err := conn.ReadMsgUnix(make([]byte, 1), oob)
	if err != nil {
		return -1, -1, err
	}
	msgs, err := unix.ParseSocketControlMessage(oob[:oobn])
	if err != nil || len(msgs) != 1 {
		return -1, -1, errors.New("the handoff carried no descriptors")
	}
	fds, err := unix.ParseUnixRights(&msgs[0])
	if err != nil || len(fds) != 2 {
		for _, fd := range fds {
			_ = unix.Close(fd)
		}
		return -1, -1, errors.New("the handoff did not carry two listeners")
	}
	for _, fd := range fds {
		unix.CloseOnExec(fd)
	}
	return fds[0], fds[1], nil
}

// listenVsock listens on port of this guest: the first process's alone.
func listenVsock(port uint32) (int, error) {
	fd, err := unix.Socket(unix.AF_VSOCK, unix.SOCK_STREAM|unix.SOCK_CLOEXEC, 0)
	if err != nil {
		return -1, err
	}
	if err := unix.Bind(fd, &unix.SockaddrVM{CID: unix.VMADDR_CID_ANY, Port: port}); err != nil {
		_ = unix.Close(fd)
		return -1, err
	}
	if err := unix.Listen(fd, 16); err != nil {
		_ = unix.Close(fd)
		return -1, err
	}
	return fd, nil
}

// acceptHost returns the next connection from the host's CID, closing any
// other: only the host is answered.
func acceptHost(fd int) (*vsockConn, error) {
	for {
		nfd, sa, err := unix.Accept4(fd, unix.SOCK_CLOEXEC)
		if errors.Is(err, unix.EINTR) || errors.Is(err, unix.ECONNABORTED) {
			continue
		}
		if err != nil {
			return nil, err
		}
		if vsa, ok := sa.(*unix.SockaddrVM); !ok || vsa.CID != vm.HostCID {
			_ = unix.Close(nfd)
			continue
		}
		return &vsockConn{fd: nfd}, nil
	}
}

// vsockConn is an accepted vsock connection, read and written blocking:
// Go's net package has no vsock, and each connection has its own goroutines.
type vsockConn struct {
	fd   int
	once sync.Once
}

func (c *vsockConn) Read(b []byte) (int, error) {
	for {
		n, err := unix.Read(c.fd, b)
		if errors.Is(err, unix.EINTR) {
			continue
		}
		if err != nil {
			return 0, err
		}
		if n == 0 && len(b) > 0 {
			return 0, io.EOF
		}
		return n, nil
	}
}

func (c *vsockConn) Write(b []byte) (int, error) {
	written := 0
	for written < len(b) {
		n, err := unix.Write(c.fd, b[written:])
		if errors.Is(err, unix.EINTR) {
			continue
		}
		if err != nil {
			return written, err
		}
		written += n
	}
	return written, nil
}

func (c *vsockConn) CloseWrite() error { return unix.Shutdown(c.fd, unix.SHUT_WR) }

func (c *vsockConn) Close() error {
	err := error(nil)
	c.once.Do(func() { err = unix.Close(c.fd) })
	return err
}

// halfCloser is a connection whose writing side ends apart from its reading.
type halfCloser interface {
	io.ReadWriteCloser
	CloseWrite() error
}

// join carries bytes both ways between a and b until both directions end,
// ending each writer when its reader does.
func join(a, b io.ReadWriteCloser) {
	var wg sync.WaitGroup
	carry := func(dst, src io.ReadWriteCloser) {
		defer wg.Done()
		_, _ = io.Copy(dst, src)
		if hc, ok := dst.(halfCloser); ok {
			_ = hc.CloseWrite()
		} else {
			_ = dst.Close()
		}
	}
	wg.Add(2)
	go carry(a, b)
	go carry(b, a)
	wg.Wait()
	_ = a.Close()
	_ = b.Close()
}

// half is one side of an attach connection, waiting for the other.
type half struct {
	conn  io.ReadWriteCloser
	host  bool
	timer *time.Timer
}

// pairs holds each attach connection until its other half arrives, by the
// token both present, and counts the connections admitted and not yet
// joined, closed or timed out.
type pairs struct {
	mu        sync.Mutex
	waiting   map[string]*half
	unmatched int
}

// admit counts one more connection not yet matched, or refuses it when
// maxUnmatched are held already.
func (p *pairs) admit() bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.unmatched >= maxUnmatched {
		return false
	}
	p.unmatched++
	return true
}

// leave counts out an admitted connection that will never be offered.
func (p *pairs) leave() {
	p.mu.Lock()
	p.unmatched--
	p.mu.Unlock()
}

// offer joins conn, an admitted connection, with the waiting half of token
// from the other side, or waits pairWait for it. A second half from the
// same side ends both: a token is one spawn's. Either way both leave the
// count of the unmatched.
func (p *pairs) offer(token string, conn io.ReadWriteCloser, host bool) {
	p.mu.Lock()
	other, ok := p.waiting[token]
	if ok {
		delete(p.waiting, token)
		other.timer.Stop()
		p.unmatched -= 2
	}
	if !ok {
		h := &half{conn: conn, host: host}
		h.timer = time.AfterFunc(pairWait, func() {
			p.mu.Lock()
			if p.waiting[token] == h {
				delete(p.waiting, token)
				p.unmatched--
			}
			p.mu.Unlock()
			_ = conn.Close()
		})
		p.waiting[token] = h
		p.mu.Unlock()
		return
	}
	p.mu.Unlock()
	if other.host == host {
		_ = other.conn.Close()
		_ = conn.Close()
		return
	}
	go join(other.conn, conn)
}

// token reads conn's first frame, its attach token, within pairWait.
func token(conn io.ReadWriteCloser, deadline func(time.Time) error) (string, error) {
	if deadline != nil {
		_ = deadline(time.Now().Add(pairWait))
		defer func() { _ = deadline(time.Time{}) }()
	}
	buf := make([]byte, frame.MaxPayload)
	stream, payload, err := frame.Read(conn, buf)
	if err != nil {
		return "", err
	}
	if stream != frame.StreamAttach || len(payload) == 0 {
		return "", errors.New("the first frame is not an attach token")
	}
	return string(payload), nil
}

// acceptAttach takes the keeper's relays on the attach socket, each
// admitted as one of the unmatched or closed at once.
func acceptAttach(l net.Listener, p *pairs) {
	for {
		conn, err := l.Accept()
		if err != nil {
			logf("relay: the attach socket: %v", err)
			return
		}
		if !p.admit() {
			_ = conn.Close()
			continue
		}
		go func() {
			uc := conn.(*net.UnixConn)
			t, err := token(uc, uc.SetReadDeadline)
			if err != nil {
				_ = conn.Close()
				p.leave()
				return
			}
			p.offer(t, uc, false)
		}()
	}
}

// acceptHostAttach takes the host's attach connections on AttachPort, each
// admitted as one of the unmatched or closed at once.
func acceptHostAttach(fd int, p *pairs) {
	for {
		conn, err := acceptHost(fd)
		if err != nil {
			logf("relay: the host's attach port: %v", err)
			return
		}
		if !p.admit() {
			_ = conn.Close()
			continue
		}
		go func() {
			tv := unix.NsecToTimeval(pairWait.Nanoseconds())
			_ = unix.SetsockoptTimeval(conn.fd, unix.SOL_SOCKET, unix.SO_RCVTIMEO, &tv)
			t, err := token(conn, nil)
			_ = unix.SetsockoptTimeval(conn.fd, unix.SOL_SOCKET, unix.SO_RCVTIMEO, &unix.Timeval{})
			if err != nil {
				_ = conn.Close()
				p.leave()
				return
			}
			p.offer(t, conn, true)
		}()
	}
}

func jsonLine(v any) ([]byte, error) {
	b, err := json.Marshal(v)
	return append(b, '\n'), err
}
