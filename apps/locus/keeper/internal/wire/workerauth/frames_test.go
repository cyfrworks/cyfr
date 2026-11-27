// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package workerauth

import (
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

type frameVectors struct {
	FrameCases struct {
		MaxFrameBytes int `json:"max_frame_bytes"`
		MaxChunkBytes int `json:"max_chunk_bytes"`
	} `json:"frame_cases"`
	FrameSplits []struct {
		Why    string   `json:"why"`
		Stream string   `json:"stream_hex"`
		Frames []string `json:"frames_hex"`
		Rest   string   `json:"rest_hex"`
		Error  *string  `json:"error"`
	} `json:"frame_splits"`
	FrameBodyBytes []struct {
		Why   string `json:"why"`
		Frame string `json:"frame_hex"`
		Bytes int    `json:"bytes"`
	} `json:"frame_body_bytes"`
}

// A stream of answer frames splits, unopened, as Prima splits it, and a
// frame's body is counted from its sealed value's length alone.
func TestEveryFrameStreamSplitsAndCountsAsPrimaDoes(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "..", "..", "..", "tests", "fixtures", "host_api.json"))
	if err != nil {
		t.Fatal(err)
	}
	var v frameVectors
	if err := json.Unmarshal(data, &v); err != nil {
		t.Fatal(err)
	}
	if v.FrameCases.MaxFrameBytes != MaxFrameBytes || v.FrameCases.MaxChunkBytes != MaxChunkBytes {
		t.Fatalf("bounds %+v", v.FrameCases)
	}
	if len(v.FrameSplits) < 10 || len(v.FrameBodyBytes) < 10 {
		t.Fatalf("%d splits, %d counts", len(v.FrameSplits), len(v.FrameBodyBytes))
	}
	for _, c := range v.FrameSplits {
		stream, _ := hex.DecodeString(c.Stream)
		frames, rest, err := SplitFrames(stream)
		if c.Error != nil {
			if err == nil || err.Error() != *c.Error {
				t.Errorf("%s: %v, want %s", c.Why, err, *c.Error)
			}
			continue
		}
		got := make([]string, len(frames))
		for i, f := range frames {
			got[i] = hex.EncodeToString(f)
		}
		if err != nil || len(got) != len(c.Frames) || hex.EncodeToString(rest) != c.Rest {
			t.Errorf("%s: %v rest %x, %v", c.Why, got, rest, err)
			continue
		}
		for i := range got {
			if got[i] != c.Frames[i] {
				t.Errorf("%s: frame %d", c.Why, i)
			}
		}
	}
	for _, c := range v.FrameBodyBytes {
		frame, _ := hex.DecodeString(c.Frame)
		if got := FrameBodyBytes(frame); got != c.Bytes {
			t.Errorf("%s: %d, want %d", c.Why, got, c.Bytes)
		}
	}
}
