// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package relay carries one spawned process's stdio between its pipes and
// the client. `cyfr-spawn relay` runs as the client's user, holding the
// parent ends of the backend's pipes; it connects to the client's attach
// socket, presents the spawn's token and then frames the three streams
// (package frame) over that one connection. The client therefore reaches a
// backend's stdio without ever sharing its uid, and the spawner never reads
// backend output.
package relay

import (
	"errors"
	"io"
	"net"
	"sync"
	"time"

	"github.com/cyfr/spawn/internal/frame"
	"github.com/cyfr/spawn/internal/protocol"
)

// Spec is what the spawner hands a relay over its spec pipe.
type Spec struct {
	Path  string `json:"path"`
	Token string `json:"token"`
}

// Validate checks the attach target.
func (s Spec) Validate() error {
	return protocol.ValidateAttach(protocol.Attach{Path: s.Path, Token: s.Token})
}

// DialTimeout bounds the connection to the attach socket.
const DialTimeout = 10 * time.Second

var errProtocol = errors.New("relay: the client sent a frame on a stream other than stdin")

// Run relays until the backend has closed both stdout and stderr, or the
// client has closed the connection. Bytes from stream 0 go to stdin and a
// zero-length stream 0 frame closes it; stdout and stderr go out as streams
// 1 and 2, each ended by a zero-length frame. Every file is closed on return.
func Run(spec Spec, stdin io.WriteCloser, stdout, stderr io.ReadCloser, dialTimeout time.Duration) error {
	closeAll := func() {
		_ = stdin.Close()
		_ = stdout.Close()
		_ = stderr.Close()
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

	outputs := make(chan error, 2)
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
	go pump(stdout, frame.StreamStdout)
	go pump(stderr, frame.StreamStderr)

	inputs := make(chan error, 1)
	go func() {
		buf := make([]byte, frame.MaxPayload)
		stdinOpen := true
		for {
			stream, payload, err := frame.Read(conn, buf)
			if err != nil {
				if errors.Is(err, io.EOF) {
					err = nil
				}
				inputs <- err
				return
			}
			if stream != frame.StreamStdin {
				inputs <- errProtocol
				return
			}
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
		}
	}()

	for open := 2; open > 0; {
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
