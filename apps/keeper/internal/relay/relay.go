// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package relay carries one spawned process's stdio, and its control
// channel when it has one, between its pipes and the client. `cyfr-keeper
// relay` runs as the client's user, holding the parent ends of the
// backend's pipes; it connects to the client's attach socket, presents the
// spawn's token and then frames the streams (package frame) over that one
// connection. The client therefore reaches a backend's stdio without ever
// sharing its uid, and the spawner never reads backend output.
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

// Spec is what the spawner hands a relay over its spec pipe: the attach
// target, and whether the spawn has a control channel on ControlFD.
type Spec struct {
	Path    string `json:"path"`
	Token   string `json:"token"`
	Control bool   `json:"control"`
}

// Validate checks the attach target.
func (s Spec) Validate() error {
	return protocol.ValidateAttach(protocol.Attach{Path: s.Path, Token: s.Token})
}

// Control is the relay's end of a spawn's control channel: the socket
// whose other end is the backend's file descriptor 3. CloseWrite ends the
// backend's reading side while the relay keeps reading what the backend
// writes.
type Control interface {
	io.ReadWriteCloser
	CloseWrite() error
}

// DialTimeout bounds the connection to the attach socket.
const DialTimeout = 10 * time.Second

var errProtocol = errors.New("relay: the client sent a frame on a stream other than stdin or control")

// Run relays until the backend has closed stdout, stderr and, when it has
// one, its control channel, or the client has closed the connection. Bytes
// from stream 0 go to stdin and a zero-length stream 0 frame closes it;
// stdout and stderr go out as streams 1 and 2, each ended by a zero-length
// frame. With control, bytes from frame.StreamControl go to the channel, a
// zero-length one closes its writing side, and what the backend writes to
// the channel goes out on the same stream, ended by a zero-length frame
// once the backend's end is closed. control is nil for a spawn without a
// channel, and a control frame from the client is then a protocol fault.
// Every file is closed on return.
func Run(spec Spec, stdin io.WriteCloser, stdout, stderr io.ReadCloser, control Control, dialTimeout time.Duration) error {
	closeAll := func() {
		_ = stdin.Close()
		_ = stdout.Close()
		_ = stderr.Close()
		if control != nil {
			_ = control.Close()
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

	outputs := make(chan error, 3)
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

	inputs := make(chan error, 1)
	go func() {
		buf := make([]byte, frame.MaxPayload)
		stdinOpen := true
		controlOpen := control != nil
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
				if !controlOpen {
					continue
				}
				if len(payload) == 0 {
					_ = control.CloseWrite()
					controlOpen = false
					continue
				}
				if _, err := control.Write(payload); err != nil {
					_ = control.CloseWrite()
					controlOpen = false
				}
			default:
				inputs <- errProtocol
				return
			}
		}
	}()

	for open > 0 {
		select {
		case err := <-outputs:
			if err != nil {
				return err
			}
			open--
		case err := <-inputs:
			return err
		}
	}
	return nil
}
