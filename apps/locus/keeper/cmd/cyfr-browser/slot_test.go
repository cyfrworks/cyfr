// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"reflect"
	"testing"
	"time"
)

// sent is what the host reads of a slot: each frame since the last look,
// as `t id/seq` (a res) or `t id`.
type sent struct {
	out   bytes.Buffer
	in    reader
	parts map[int64]map[int][]byte
}

func (h *sent) look(t *testing.T) []string {
	t.Helper()
	frames := []string{}
	for _, body := range h.in.feed(h.out.Bytes()) {
		var m struct {
			T    string `json:"t"`
			ID   int64  `json:"id"`
			Seq  int    `json:"seq"`
			Part string `json:"part"`
		}
		if err := json.Unmarshal(body, &m); err != nil {
			t.Fatalf("a frame of no JSON: %s", body)
		}
		if m.T != "res" {
			frames = append(frames, fmt.Sprintf("%s %d", m.T, m.ID))
			continue
		}
		frames = append(frames, fmt.Sprintf("res %d/%d", m.ID, m.Seq))
		part, err := base64.StdEncoding.DecodeString(m.Part)
		if err != nil {
			t.Fatalf("a part of no base64: %s", body)
		}
		if h.parts[m.ID] == nil {
			h.parts[m.ID] = map[int][]byte{}
		}
		h.parts[m.ID][m.Seq] = part
	}
	h.out.Reset()
	return frames
}

func (h *sent) text(id int64) string {
	var text []byte
	for seq := 0; h.parts[id][seq] != nil; seq++ {
		text = append(text, h.parts[id][seq]...)
	}
	return string(text)
}

type clock struct{ at time.Time }

func (c *clock) now() time.Time { return c.at }

func newTestSlot(chunk int, keep time.Duration) (*slot, *sent, *clock) {
	h := &sent{in: reader{max: maxToHost}, parts: map[int64]map[int][]byte{}}
	c := &clock{at: time.Unix(1_000_000, 0)}
	s := newSlot(&h.out, chunk, keep)
	s.now = c.now
	return s, h, c
}

func expectFrames(t *testing.T, h *sent, step string, want ...string) {
	t.Helper()
	if got := h.look(t); !reflect.DeepEqual(got, append([]string{}, want...)) {
		t.Fatalf("%s: the host read %q, want %q", step, got, want)
	}
}

func check(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

func TestOneChunkUnacknowledged(t *testing.T) {
	s, h, _ := newTestSlot(4, time.Minute)
	check(t, s.ready(1, []byte("abcdefghij")))
	check(t, s.ready(2, []byte("xyz")))
	expectFrames(t, h, "two responses ready", "res 1/0")
	check(t, s.ack(1, 1))
	check(t, s.ack(2, 0))
	expectFrames(t, h, "an ack of no chunk sent")
	check(t, s.ack(1, 0))
	expectFrames(t, h, "the ack of chunk 0", "res 1/1")
	check(t, s.ack(1, 1))
	expectFrames(t, h, "the ack of chunk 1", "res 1/2")
	check(t, s.ack(1, 2))
	expectFrames(t, h, "the ack of the first response's last chunk", "res 2/0")
	check(t, s.ack(2, 0))
	expectFrames(t, h, "the ack of the last response's last chunk")
	if h.text(1) != "abcdefghij" || h.text(2) != "xyz" || len(s.kept) != 0 {
		t.Fatalf("the host has %q and %q, the slot keeps %d", h.text(1), h.text(2), len(s.kept))
	}
	check(t, s.again(1, 0))
	expectFrames(t, h, "again for a response acknowledged whole", "gone 1")
}

func TestAgainRewinds(t *testing.T) {
	s, h, _ := newTestSlot(4, time.Minute)
	check(t, s.ready(1, []byte("abcdefghij")))
	check(t, s.ready(2, []byte("klmnopq")))
	expectFrames(t, h, "two responses ready", "res 1/0")
	check(t, s.ack(1, 0))
	expectFrames(t, h, "the ack of chunk 0", "res 1/1")
	check(t, s.again(1, 0))
	expectFrames(t, h, "again for the unacknowledged response", "res 1/0")
	// The host holds chunk 1 from before the rewind: its ack of 1
	// acknowledges the run up to it, so chunk 1 is not sent again.
	check(t, s.ack(1, 1))
	expectFrames(t, h, "the ack of the run past the chunk again replaced", "res 1/2")
	check(t, s.again(2, 1))
	expectFrames(t, h, "again for a response waiting its turn")
	for seq := range 3 {
		check(t, s.ack(1, seq))
	}
	expectFrames(t, h, "the rewound response acknowledged", "res 2/1")
	check(t, s.ack(2, 1))
	expectFrames(t, h, "the last chunk acknowledged")
	if h.text(1) != "abcdefghij" {
		t.Fatalf("the host has %q", h.text(1))
	}
}

// An ack names the last chunk of the unbroken run the host holds: an ack
// past the unacknowledged chunk releases the slot and skips what the host
// holds, its last chunk ends the response, and one past the furthest chunk
// sent changes nothing.
func TestAckIsCumulative(t *testing.T) {
	s, h, _ := newTestSlot(4, time.Minute)
	check(t, s.ready(1, []byte("abcdefghijklmnop")))
	check(t, s.ready(2, []byte("xyz")))
	expectFrames(t, h, "two responses ready", "res 1/0")
	check(t, s.ack(1, 0))
	check(t, s.ack(1, 1))
	check(t, s.ack(1, 2))
	expectFrames(t, h, "the run acknowledged chunk by chunk", "res 1/1", "res 1/2", "res 1/3")
	check(t, s.again(1, 1))
	expectFrames(t, h, "again from chunk 1", "res 1/1")
	check(t, s.ack(1, 3))
	expectFrames(t, h, "the host holds the rest: the response ends, the next goes", "res 2/0")
	if _, kept := s.kept[1]; kept {
		t.Fatal("a response acknowledged whole is still kept")
	}
	check(t, s.ack(2, 5))
	expectFrames(t, h, "an ack past the furthest chunk sent")
	check(t, s.ack(2, 0))
	expectFrames(t, h, "the last response acknowledged")
	if h.text(1) != "abcdefghijklmnop" || h.text(2) != "xyz" || len(s.kept) != 0 {
		t.Fatalf("the host has %q and %q, the slot keeps %d", h.text(1), h.text(2), len(s.kept))
	}
}

func TestKeepExpires(t *testing.T) {
	s, h, c := newTestSlot(4, time.Minute)
	check(t, s.ready(1, []byte("abcdefgh")))
	c.at = c.at.Add(30 * time.Second)
	check(t, s.ready(2, []byte("ijkl")))
	expectFrames(t, h, "two responses ready", "res 1/0")
	c.at = c.at.Add(30 * time.Second)
	check(t, s.expire())
	expectFrames(t, h, "the first kept past keep, unacknowledged", "res 2/0")
	check(t, s.ack(1, 0))
	check(t, s.again(1, 0))
	expectFrames(t, h, "again for the expired response", "gone 1")
	c.at = c.at.Add(30 * time.Second)
	check(t, s.expire())
	check(t, s.again(2, 0))
	expectFrames(t, h, "again for the second, expired with its chunk unacknowledged", "gone 2")
}

func TestUnknownIDIsGone(t *testing.T) {
	s, h, _ := newTestSlot(4, time.Minute)
	check(t, s.again(99, 0))
	expectFrames(t, h, "again for an id never seen", "gone 99")
}

func TestAgainWhileRunning(t *testing.T) {
	s, h, _ := newTestSlot(4, time.Minute)
	if run, err := s.take(5); !run || err != nil {
		t.Fatalf("a new request did not run: %v %v", run, err)
	}
	check(t, s.again(5, 1))
	expectFrames(t, h, "again for a running request")
	check(t, s.ready(5, []byte("abcdef")))
	expectFrames(t, h, "its response ready", "res 5/0")
}

// Nothing the host sends runs a request twice.
func TestRequestRunsOnce(t *testing.T) {
	s, h, _ := newTestSlot(4, time.Minute)
	for step, want := range []bool{true, false} {
		if run, err := s.take(5); run != want || err != nil {
			t.Fatalf("take %d: %v %v", step, run, err)
		}
	}
	check(t, s.ready(5, []byte("ab")))
	if run, err := s.take(5); run || err != nil {
		t.Fatalf("a request whose response is held ran again: %v %v", run, err)
	}
	check(t, s.ack(5, 0))
	expectFrames(t, h, "its response", "res 5/0")
	if run, err := s.take(5); run || err != nil {
		t.Fatalf("a request whose response was acknowledged ran again: %v %v", run, err)
	}
	expectFrames(t, h, "the request sent again", "gone 5")
}

func TestKeptBound(t *testing.T) {
	s, h, c := newTestSlot(4, time.Minute)
	for id := range int64(maxKept + 1) {
		c.at = c.at.Add(time.Millisecond)
		check(t, s.ready(id, []byte("abcd")))
	}
	expectFrames(t, h, "past the bound, the oldest response goes", "res 0/0", "res 1/0")
	check(t, s.again(0, 0))
	expectFrames(t, h, "again for the response dropped", "gone 0")
	if len(s.kept) != maxKept {
		t.Fatalf("the slot keeps %d responses", len(s.kept))
	}
}
