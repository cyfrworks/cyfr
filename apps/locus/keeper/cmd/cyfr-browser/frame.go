// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"strconv"
)

// The framing tests/fixtures/browser_frames.json defines (its "comment").
const (
	frameStart  = 0x1e
	frameEnd    = '\n'
	headerBytes = 1 + 2 + 8 + 16
	// maxToHost bounds a frame's body the host takes; maxToDriver one this
	// driver takes.
	maxToHost   = 131072
	maxToDriver = 8 << 20
)

// encode frames one JSON body.
func encode(body []byte) []byte {
	sum := sha256.Sum256(body)
	out := make([]byte, 0, headerBytes+len(body)+1)
	out = append(out, frameStart, 'B', '1')
	out = fmt.Appendf(out, "%08x", len(body))
	out = hex.AppendEncode(out, sum[:8])
	out = append(out, body...)
	return append(out, frameEnd)
}

// reader takes whole frames out of a byte stream that may have been cut
// anywhere. It never takes a frame it cannot prove whole: what it does not
// take it skips to the next 0x1E, and what may yet complete it holds.
type reader struct {
	max int
	buf []byte
	// scanned counts the body bytes of the frame at buf[0] already known
	// to hold no 0x1E, so a large frame arriving in many pieces is scanned
	// once.
	scanned int
}

// feed adds the bytes that arrived and answers the bodies they complete.
func (r *reader) feed(data []byte) [][]byte {
	r.buf = append(r.buf, data...)
	var bodies [][]byte
	for {
		start := bytes.IndexByte(r.buf, frameStart)
		if start < 0 {
			r.buf, r.scanned = r.buf[:0], 0
			return bodies
		}
		if start > 0 {
			r.buf, r.scanned = r.buf[start:], 0
		}
		body, used := r.take()
		if used == 0 {
			return bodies
		}
		if body != nil {
			bodies = append(bodies, body)
		}
		r.buf, r.scanned = r.buf[used:], 0
	}
}

// take reads the frame at buf[0]: its body and the bytes it used; nil and
// 1 to skip this 0x1E; nil and 0 to wait for more bytes.
func (r *reader) take() ([]byte, int) {
	b := r.buf
	for i := 1; i < headerBytes && i < len(b); i++ {
		if !headerByte(i, b[i]) {
			return nil, 1
		}
	}
	if len(b) < headerBytes {
		return nil, 0
	}
	length, _ := strconv.ParseUint(string(b[3:11]), 16, 32)
	if length == 0 || length > uint64(r.max) {
		return nil, 1
	}
	end := headerBytes + int(length)
	// A body holds no 0x1E, so one inside the claimed body proves this
	// frame cut: the frame that 0x1E starts is read at once, not after the
	// claimed length has arrived.
	from, upto := headerBytes+r.scanned, min(len(b), end)
	if from < upto {
		if bytes.IndexByte(b[from:upto], frameStart) >= 0 {
			return nil, 1
		}
		r.scanned = upto - headerBytes
	}
	if len(b) <= end {
		return nil, 0
	}
	if b[end] != frameEnd {
		return nil, 1
	}
	body := b[headerBytes:end]
	sum := sha256.Sum256(body)
	if !bytes.Equal(hex.AppendEncode(nil, sum[:8]), b[11:headerBytes]) {
		return nil, 1
	}
	return bytes.Clone(body), end + 1
}

// headerByte says whether c may stand at offset i of a frame's header.
func headerByte(i int, c byte) bool {
	switch i {
	case 1:
		return c == 'B'
	case 2:
		return c == '1'
	default:
		return c >= '0' && c <= '9' || c >= 'a' && c <= 'f'
	}
}
