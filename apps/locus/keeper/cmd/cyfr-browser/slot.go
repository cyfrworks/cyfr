// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

import (
	"encoding/base64"
	"encoding/json"
	"io"
	"time"
)

const (
	// maxKept bounds the responses held at once; past it the oldest goes.
	maxKept = 64
	// maxChunk keeps a `res` frame, its chunk in base64 with the message
	// around it, within the host's bound.
	maxChunk = (maxToHost - 256) / 4 * 3
)

type helloMessage struct {
	T      string `json:"t"`
	V      int    `json:"v"`
	Chunk  int    `json:"chunk"`
	KeepMS int64  `json:"keep_ms"`
	Error  string `json:"error,omitempty"`
}

type resMessage struct {
	T    string `json:"t"`
	ID   int64  `json:"id"`
	Seq  int    `json:"seq"`
	Of   int    `json:"of"`
	Part string `json:"part"`
}

type goneMessage struct {
	T  string `json:"t"`
	ID int64  `json:"id"`
}

// response is one request's answer, held until the host has it whole.
type response struct {
	text []byte
	of   int
	// next is the chunk the slot sends next.
	next int
	// high is the furthest chunk ever sent, -1 before the first.
	high int
	made time.Time
}

// chunkRef names the one `res` frame the host has not acknowledged.
type chunkRef struct {
	id  int64
	seq int
}

// slot is the driver's single send slot. Only one `res` frame is ever
// unacknowledged, so what the driver prints past the host's last
// acknowledgement is one chunk, well under the tail the session keeps; a
// response's chunks go out in order, responses in the order they were
// made ready. Every method runs on the serve loop's goroutine.
type slot struct {
	out   io.Writer
	chunk int
	keep  time.Duration
	now   func() time.Time

	kept map[int64]*response
	// queue holds the responses with chunks left to send, front first.
	queue   []int64
	sent    *chunkRef
	running map[int64]bool
	// taken holds every request id this driver has run, so no request runs
	// twice whatever the host sends.
	taken map[int64]bool
}

func newSlot(out io.Writer, chunk int, keep time.Duration) *slot {
	return &slot{
		out: out, chunk: chunk, keep: keep, now: time.Now,
		kept: map[int64]*response{}, running: map[int64]bool{}, taken: map[int64]bool{},
	}
}

// write frames one message to the host.
func (s *slot) write(message any) error {
	body, err := json.Marshal(message)
	if err != nil {
		return err
	}
	_, err = s.out.Write(encode(body))
	return err
}

// take answers whether request id is new and so runs. One taken before
// runs no more: while it runs or its response is held that response
// serves it, and once dropped the host is told it is gone.
func (s *slot) take(id int64) (bool, error) {
	if !s.taken[id] {
		s.taken[id] = true
		s.running[id] = true
		return true, nil
	}
	if s.running[id] || s.kept[id] != nil {
		return false, nil
	}
	return false, s.write(goneMessage{T: "gone", ID: id})
}

// ready holds request id's response text and sends from it when the slot
// is free.
func (s *slot) ready(id int64, text []byte) error {
	delete(s.running, id)
	if len(s.kept) >= maxKept {
		s.drop(s.oldest())
	}
	s.kept[id] = &response{text: text, of: (len(text) + s.chunk - 1) / s.chunk, high: -1, made: s.now()}
	s.queue = append(s.queue, id)
	return s.pump()
}

// ack takes the host's acknowledgement of response id up to chunk seq: it
// names the last chunk of the unbroken run the host holds, so it
// acknowledges every chunk of the response up to it. It releases the slot
// when the unacknowledged chunk is one of them, sends nothing the host
// holds again, and the ack of the response's last chunk drops the
// response, the host holding it whole. An ack past the furthest chunk sent
// names chunks the host cannot hold, and changes nothing.
func (s *slot) ack(id int64, seq int) error {
	r := s.kept[id]
	if r == nil || seq < 0 || seq > r.high {
		return nil
	}
	if s.sent != nil && s.sent.id == id && s.sent.seq <= seq {
		s.sent = nil
	}
	if seq == r.of-1 {
		s.drop(id)
	} else if r.next <= seq {
		r.next = seq + 1
	}
	return s.pump()
}

// again rewinds response id to chunk seq. A rewound unacknowledged chunk is
// replaced at once by chunk seq; another response waits its turn. A
// request still running is remembered by take and is answered when ready.
func (s *slot) again(id int64, seq int) error {
	if s.running[id] {
		return nil
	}
	r := s.kept[id]
	if r == nil {
		return s.write(goneMessage{T: "gone", ID: id})
	}
	if seq < 0 || seq >= r.of {
		return nil
	}
	r.next = seq
	s.remove(id)
	if s.sent != nil && s.sent.id == id {
		s.sent = nil
		s.queue = append([]int64{id}, s.queue...)
	} else {
		s.queue = append(s.queue, id)
	}
	return s.pump()
}

// expire drops every response kept past keep since it was made.
func (s *slot) expire() error {
	for id, r := range s.kept {
		if s.now().Sub(r.made) >= s.keep {
			s.drop(id)
		}
	}
	return s.pump()
}

// pump sends the next chunk when no chunk is unacknowledged.
func (s *slot) pump() error {
	for s.sent == nil && len(s.queue) > 0 {
		id := s.queue[0]
		r := s.kept[id]
		if r == nil || r.next >= r.of {
			s.queue = s.queue[1:]
			continue
		}
		seq := r.next
		r.next++
		r.high = max(r.high, seq)
		if r.next >= r.of {
			s.queue = s.queue[1:]
		}
		s.sent = &chunkRef{id, seq}
		end := min((seq+1)*s.chunk, len(r.text))
		part := base64.StdEncoding.EncodeToString(r.text[seq*s.chunk : end])
		if err := s.write(resMessage{T: "res", ID: id, Seq: seq, Of: r.of, Part: part}); err != nil {
			return err
		}
	}
	return nil
}

func (s *slot) drop(id int64) {
	delete(s.kept, id)
	s.remove(id)
	if s.sent != nil && s.sent.id == id {
		s.sent = nil
	}
}

func (s *slot) remove(id int64) {
	for i, queued := range s.queue {
		if queued == id {
			s.queue = append(s.queue[:i:i], s.queue[i+1:]...)
			return
		}
	}
}

func (s *slot) oldest() int64 {
	var oldest int64
	var at time.Time
	for id, r := range s.kept {
		if at.IsZero() || r.made.Before(at) {
			oldest, at = id, r.made
		}
	}
	return oldest
}
