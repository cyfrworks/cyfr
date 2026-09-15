// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package frame is the codec of the attach connection between a relay and
// the spawner's client. A frame is a 1-byte stream id, a 4-byte big-endian
// payload length and the payload. A zero-length frame on a data stream
// marks the end of that stream.
package frame

import (
	"encoding/binary"
	"errors"
	"fmt"
	"io"
)

// Stream ids.
const (
	// StreamStdin carries bytes for the backend's standard input (client to relay).
	StreamStdin byte = 0
	// StreamStdout carries the backend's standard output (relay to client).
	StreamStdout byte = 1
	// StreamStderr carries the backend's standard error (relay to client).
	StreamStderr byte = 2
	// StreamAttach is the relay's first frame; its payload is the attach token.
	StreamAttach byte = 3
)

const (
	// HeaderSize is the length of a frame header in bytes.
	HeaderSize = 5
	// MaxPayload bounds one frame's payload; writers split larger data.
	MaxPayload = 64 << 10
)

var (
	// ErrTooLarge reports a frame whose declared length exceeds MaxPayload.
	ErrTooLarge = errors.New("frame: payload exceeds the maximum")
	// ErrUnknownStream reports a stream id outside the defined set.
	ErrUnknownStream = errors.New("frame: unknown stream id")
)

func validStream(stream byte) bool {
	return stream <= StreamAttach
}

// Append encodes one frame onto dst.
func Append(dst []byte, stream byte, payload []byte) ([]byte, error) {
	if !validStream(stream) {
		return dst, ErrUnknownStream
	}
	if len(payload) > MaxPayload {
		return dst, ErrTooLarge
	}
	var header [HeaderSize]byte
	header[0] = stream
	binary.BigEndian.PutUint32(header[1:], uint32(len(payload)))
	dst = append(dst, header[:]...)
	return append(dst, payload...), nil
}

// Write encodes one frame and writes it with a single call to w.
func Write(w io.Writer, stream byte, payload []byte) error {
	buf, err := Append(make([]byte, 0, HeaderSize+len(payload)), stream, payload)
	if err != nil {
		return err
	}
	_, err = w.Write(buf)
	return err
}

// Read reads one frame from r into buf, which must hold MaxPayload bytes.
// The returned payload aliases buf. A clean end of input before a header
// is io.EOF; an end inside a frame is io.ErrUnexpectedEOF.
func Read(r io.Reader, buf []byte) (byte, []byte, error) {
	if len(buf) < MaxPayload {
		return 0, nil, fmt.Errorf("frame: read buffer holds %d bytes, need %d", len(buf), MaxPayload)
	}
	var header [HeaderSize]byte
	if _, err := io.ReadFull(r, header[:]); err != nil {
		return 0, nil, err
	}
	stream := header[0]
	if !validStream(stream) {
		return 0, nil, ErrUnknownStream
	}
	n := binary.BigEndian.Uint32(header[1:])
	if n > MaxPayload {
		return 0, nil, ErrTooLarge
	}
	if _, err := io.ReadFull(r, buf[:n]); err != nil {
		if err == io.EOF {
			err = io.ErrUnexpectedEOF
		}
		return 0, nil, err
	}
	return stream, buf[:n], nil
}
