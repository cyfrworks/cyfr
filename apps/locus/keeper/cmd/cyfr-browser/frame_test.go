// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

type frameVectors struct {
	Start       string `json:"start"`
	MaxToHost   int    `json:"max_to_host"`
	MaxToDriver int    `json:"max_to_driver"`
	MaxResponse int    `json:"max_response"`
	Encode      []struct {
		Name, Body, Frame string
	} `json:"encode"`
	Decode []struct {
		Name   string   `json:"name"`
		Max    int      `json:"max"`
		Stream []string `json:"stream"`
		Frames []string `json:"frames"`
		Rest   string   `json:"rest"`
	} `json:"decode"`
}

func loadFrameVectors(t *testing.T) frameVectors {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "..", "..", "tests", "fixtures", "browser_frames.json"))
	if err != nil {
		t.Fatal(err)
	}
	var v frameVectors
	if err := json.Unmarshal(data, &v); err != nil {
		t.Fatal(err)
	}
	return v
}

func TestFrameBounds(t *testing.T) {
	v := loadFrameVectors(t)
	if v.Start != "\x1eB1" || v.MaxToHost != maxToHost || v.MaxToDriver != maxToDriver {
		t.Fatalf("the vectors' start and bounds are %q, %d, %d; the driver's \\x1eB1, %d, %d",
			v.Start, v.MaxToHost, v.MaxToDriver, maxToHost, maxToDriver)
	}
	if v.MaxResponse != maxResponse {
		t.Fatalf("the vectors bound a response at %d bytes; the driver at %d", v.MaxResponse, maxResponse)
	}
	if body := len(must(json.Marshal(resMessage{"res", 1 << 53, 1 << 30, 1 << 30, strings.Repeat("A", 4*((maxChunk+2)/3))}))); body > maxToHost {
		t.Fatalf("a res frame of the largest chunk holds %d bytes, past the host's %d", body, maxToHost)
	}
}

func TestEncodeVectors(t *testing.T) {
	for _, c := range loadFrameVectors(t).Encode {
		if got := string(encode([]byte(c.Body))); got != c.Frame {
			t.Errorf("%s: encoded %q, want %q", c.Name, got, c.Frame)
		}
	}
}

// The driver's own messages marshal to the vectors' bodies, field order
// included.
func TestMessageBodies(t *testing.T) {
	bodies := map[string]string{}
	for _, c := range loadFrameVectors(t).Encode {
		bodies[c.Name] = c.Body
	}
	for name, message := range map[string]any{
		"hello":            helloMessage{T: "hello", V: 1, Chunk: defaultChunk, KeepMS: defaultKeepMS},
		"a response chunk": resMessage{T: "res", ID: 7, Seq: 0, Of: 1, Part: "eyJvayI6eyJ0aXRsZSI6IkV4YW1wbGUifX0="},
		"gone":             goneMessage{T: "gone", ID: 7},
	} {
		if got := string(must(json.Marshal(message))); got != bodies[name] {
			t.Errorf("%s: marshals to %s, want %s", name, got, bodies[name])
		}
	}
}

// Every decode case, fed in its pieces and fed a byte at a time, gives its
// bodies and holds its rest.
func TestDecodeVectors(t *testing.T) {
	for _, c := range loadFrameVectors(t).Decode {
		var bytewise []string
		for _, piece := range c.Stream {
			for i := range len(piece) {
				bytewise = append(bytewise, piece[i:i+1])
			}
		}
		for how, pieces := range map[string][]string{"in pieces": c.Stream, "a byte at a time": bytewise} {
			r := reader{max: c.Max}
			got := []string{}
			for _, piece := range pieces {
				for _, body := range r.feed([]byte(piece)) {
					got = append(got, string(body))
				}
			}
			if !reflect.DeepEqual(got, append([]string{}, c.Frames...)) || string(r.buf) != c.Rest {
				t.Errorf("%s, %s: took %q holding %q, want %q holding %q", c.Name, how, got, r.buf, c.Frames, c.Rest)
			}
		}
	}
}

func must[T any](value T, err error) T {
	if err != nil {
		panic(err)
	}
	return value
}
