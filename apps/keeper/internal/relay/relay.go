// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package relay carries one spawned process's stdio, its control channel
// when it has one and its relay when it is isolated, between its pipes and
// sockets and the client. `cyfr-keeper relay` runs as the client's user,
// holding the parent ends of the backend's pipes; it connects to the
// client's attach socket, presents the spawn's token and then frames the
// streams (package frame) over that one connection. The client therefore
// reaches a backend's stdio without ever sharing its uid, and the keeper
// never reads backend output.
package relay

import (
	"errors"
	"io"
	"net"
	"sync"
	"time"

	"github.com/cyfr/keeper/internal/frame"
	"github.com/cyfr/keeper/internal/protocol"
)

// Spec is what the keeper hands a relay over its spec pipe: the attach
// target, whether the spawn has a control channel on ControlFD, and
// whether it has a relay on RelayFD, as every spawn of an isolated pool
// does.
type Spec struct {
	Path    string `json:"path"`
	Token   string `json:"token"`
	Control bool   `json:"control"`
	Relay   bool   `json:"relay"`
}

// Validate checks the attach target.
func (s Spec) Validate() error {
	return protocol.ValidateAttach(protocol.Attach{Path: s.Path, Token: s.Token})
}

// Control is the relay's end of a spawn's control channel or relay: the
// socket whose other end is the backend's file descriptor 3 or 4.
// CloseWrite ends the backend's reading side while the relay keeps reading
// what the backend writes.
type Control interface {
	io.ReadWriteCloser
	CloseWrite() error
}

// DialTimeout bounds the connection to the attach socket.
const DialTimeout = 10 * time.Second

var errProtocol = errors.New("relay: the client sent a frame on a stream other than stdin, control or relay")

// socketStream is a socket carried both ways on one stream: bytes from the
// client go to it, a zero-length frame from the client closes its writing
// side, and client frames after that are dropped.
type socketStream struct {
	sock Control
	open bool
}

func (s *socketStream) fromClient(payload []byte) {
	if !s.open {
		return
	}
	if len(payload) == 0 {
		_ = s.sock.CloseWrite()
		s.open = false
		return
	}
	if _, err := s.sock.Write(payload); err != nil {
		_ = s.sock.CloseWrite()
		s.open = false
	}
}

// Run relays until the backend has closed stdout, stderr, its control
// channel when it has one and its relay once the client has used it, or
// the client has closed the connection. Bytes from stream 0 go to stdin
// and a zero-length stream 0 frame closes it; stdout and stderr go out as
// streams 1 and 2, each ended by a zero-length frame. With control, bytes
// from frame.StreamControl go to the channel, a zero-length one closes its
// writing side, and what the backend writes to the channel goes out on the
// same stream, ended by a zero-length frame once the backend's end is
// closed. The relay stream, frame.StreamRelay, is carried the same way,
// except that nothing is read from the backend's relay, nor sent on the
// stream, its end frame included, until the client's first frame on it,
// which opens it: a zero-length first frame opens it and ends nothing,
// since the service speaks second on a runner's relay. A client that
// never uses the stream never receives a frame on it, and a relay it never
// opened does not hold the run open. control and relay
// are nil for a spawn without them, and a frame from the client on the
// stream of either is then a protocol fault. Every file is closed on
// return.
func Run(spec Spec, stdin io.WriteCloser, stdout, stderr io.ReadCloser, control, relay Control, dialTimeout time.Duration) error {
	closeAll := func() {
		_ = stdin.Close()
		_ = stdout.Close()
		_ = stderr.Close()
		if control != nil {
			_ = control.Close()
		}
		if relay != nil {
			_ = relay.Close()
		}
	}
	if err := spec.Validate(); err != nil {
		closeAll()
		return err
	}
	conn, err := net.DialTimeout("unix", spec.Path, dialTimeout)
	if err != nil {
		closeAll()
		return err
	}
	defer conn.Close()
	defer closeAll()

	var writeMu sync.Mutex
	send := func(stream byte, payload []byte) error {
		writeMu.Lock()
		defer writeMu.Unlock()
		return frame.Write(conn, stream, payload)
	}
	if err := send(frame.StreamAttach, []byte(spec.Token)); err != nil {
		return err
	}

	outputs := make(chan error, 4)
	pump := func(r io.Reader, stream byte) {
		buf := make([]byte, frame.MaxPayload)
		for {
			n, err := r.Read(buf)
			if n > 0 {
				if werr := send(stream, buf[:n]); werr != nil {
					outputs <- werr
					return
				}
			}
			if err != nil {
				outputs <- send(stream, nil)
				return
			}
		}
	}
	open := 2
	go pump(stdout, frame.StreamStdout)
	go pump(stderr, frame.StreamStderr)
	if control != nil {
		open++
		go pump(control, frame.StreamControl)
	}

	// relayStarted closes on the client's first frame on the relay stream;
	// only then is the backend's relay read and its output sent.
	relayStarted := make(chan struct{})
	inputs := make(chan error, 1)
	go func() {
		buf := make([]byte, frame.MaxPayload)
		stdinOpen := true
		controlIn := &socketStream{sock: control, open: control != nil}
		relayIn := &socketStream{sock: relay, open: relay != nil}
		started := false
		for {
			stream, payload, err := frame.Read(conn, buf)
			if err != nil {
				if errors.Is(err, io.EOF) {
					err = nil
				}
				inputs <- err
				return
			}
			switch {
			case stream == frame.StreamStdin:
				if !stdinOpen {
					continue
				}
				if len(payload) == 0 {
					_ = stdin.Close()
					stdinOpen = false
					continue
				}
				if _, err := stdin.Write(payload); err != nil {
					_ = stdin.Close()
					stdinOpen = false
				}
			case stream == frame.StreamControl && control != nil:
				controlIn.fromClient(payload)
			case stream == frame.StreamRelay && relay != nil:
				if !started {
					// The client's first frame opens the stream; a
					// zero-length one opens it and nothing more.
					started = true
					close(relayStarted)
					if len(payload) == 0 {
						continue
					}
				}
				relayIn.fromClient(payload)
			default:
				inputs <- errProtocol
				return
			}
		}
	}()

	startRelay := func() {
		relayStarted = nil
		open++
		go pump(relay, frame.StreamRelay)
	}
	for {
		if open == 0 {
			// A relay the client started is carried to its end even when
			// every other output has ended first.
			select {
			case <-relayStarted:
				startRelay()
				continue
			default:
				return nil
			}
		}
		select {
		case err := <-outputs:
			if err != nil {
				return err
			}
			open--
		case <-relayStarted:
			startRelay()
		case err := <-inputs:
			return err
		}
	}
}
