// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package workerauth

import (
	"encoding/hex"
	"encoding/json"
	"testing"

	"github.com/cyfr/locus/keeper/internal/wire/wiretest"
)

// hostSections are the sections of tests/fixtures/host_api.json this test reads.
type hostSections struct {
	FrameCases struct {
		MaxFrameBytes int `json:"max_frame_bytes"`
		MaxChunkBytes int `json:"max_chunk_bytes"`
		// The frames an answer is written in: N3's service's to write.
		CallID      json.RawMessage `json:"call_id"`
		OtherCallID json.RawMessage `json:"other_call_id"`
		Cases       json.RawMessage `json:"cases"`
	} `json:"frame_cases"`
	FrameSplits    json.RawMessage `json:"frame_splits"`
	FrameBodyBytes json.RawMessage `json:"frame_body_bytes"`
}

func hostVectors(t *testing.T) hostSections {
	t.Helper()
	var s hostSections
	wiretest.Load(t, "host_api.json", &s)
	return s
}

// A stream of answer frames splits, unopened, as Prima splits it, and a
// frame's body is counted from its sealed value's length alone.
func TestEveryFrameStreamSplitsAndCountsAsPrimaDoes(t *testing.T) {
	top := hostVectors(t)
	if bounds := top.FrameCases; bounds.MaxFrameBytes != MaxFrameBytes || bounds.MaxChunkBytes != MaxChunkBytes {
		t.Fatalf("bounds %d and %d", bounds.MaxFrameBytes, bounds.MaxChunkBytes)
	}
	for _, raw := range wiretest.Cases(t, top.FrameSplits, 10) {
		var c struct {
			Why    string   `json:"why"`
			Stream string   `json:"stream_hex"`
			Frames []string `json:"frames_hex"`
			Rest   *string  `json:"rest_hex"`
			Error  *string  `json:"error"`
		}
		// A split names its frames and rest, or its error, never both.
		var members map[string]json.RawMessage
		_ = json.Unmarshal(raw, &members)
		if _, refused := members["error"]; refused {
			wiretest.Decode(t, raw, &c, []string{"why", "stream_hex", "error"})
		} else {
			wiretest.Decode(t, raw, &c, []string{"why", "stream_hex", "frames_hex", "rest_hex"})
		}
		stream, _ := hex.DecodeString(c.Stream)
		frames, rest, err := SplitFrames(stream)
		if c.Error != nil {
			if c.Frames != nil || c.Rest != nil || err == nil || err.Error() != *c.Error {
				t.Errorf("%s: %v, want %s", c.Why, err, *c.Error)
			}
			continue
		}
		got := make([]string, len(frames))
		for i, f := range frames {
			got[i] = hex.EncodeToString(f)
		}
		if err != nil || len(got) != len(c.Frames) || hex.EncodeToString(rest) != *c.Rest {
			t.Errorf("%s: %v rest %x, %v", c.Why, got, rest, err)
			continue
		}
		for i := range got {
			if got[i] != c.Frames[i] {
				t.Errorf("%s: frame %d", c.Why, i)
			}
		}
	}
	for _, raw := range wiretest.Cases(t, top.FrameBodyBytes, 10) {
		var c struct {
			Why   string `json:"why"`
			Frame string `json:"frame_hex"`
			Bytes int    `json:"bytes"`
		}
		wiretest.Decode(t, raw, &c, []string{"why", "frame_hex", "bytes"})
		frame, _ := hex.DecodeString(c.Frame)
		if got := FrameBodyBytes(frame); got != c.Bytes {
			t.Errorf("%s: %d, want %d", c.Why, got, c.Bytes)
		}
	}
}
