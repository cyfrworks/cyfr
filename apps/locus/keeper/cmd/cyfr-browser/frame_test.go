// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"testing"
)

type frameVectors struct {
	Start       string `json:"start"`
	MaxToHost   int    `json:"max_to_host"`
	MaxToDriver int    `json:"max_to_driver"`
	MaxResponse int    `json:"max_response"`
	InFlight    int    `json:"input_in_flight"`
	Put         struct {
		MaxBytes  int `json:"max_bytes"`
		MaxFiles  int `json:"max_files"`
		PartBytes int `json:"part_bytes"`
	} `json:"put"`
	Call struct {
		MaxBody int `json:"max_body"`
	} `json:"call"`
	Messages map[string]struct {
		From    string          `json:"from"`
		Fields  []string        `json:"fields"`
		Example json.RawMessage `json:"example"`
	} `json:"messages"`
	Encode []struct {
		Name, Body, Frame string
	} `json:"encode"`
	Decode []struct {
		Name   string   `json:"name"`
		Max    int      `json:"max"`
		Stream []string `json:"stream"`
		Frames []string `json:"frames"`
		Rest   string   `json:"rest"`
	} `json:"decode"`
	Input struct {
		MaxEvents int `json:"max_events"`
		Accept    []struct {
			Name  string          `json:"name"`
			Event json.RawMessage `json:"event"`
		} `json:"accept"`
		Refuse []struct {
			Name  string          `json:"name"`
			Event json.RawMessage `json:"event"`
		} `json:"refuse"`
	} `json:"input"`
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
	if body := len(must(json.Marshal(imageMessage{"image", 1 << 53, 1 << 53, strings.Repeat("A", maxImage)}))); body > maxToHost {
		t.Fatalf("an image of the largest size holds %d bytes, past the host's %d", body, maxToHost)
	}
}

// A put and a call are bounded as the vectors bound them; a part of the
// largest size fits a frame the driver takes, and a call of the largest
// body one the host takes.
func TestPutAndCallBounds(t *testing.T) {
	v := loadFrameVectors(t)
	if v.Put.MaxBytes != maxPutBytes || v.Put.MaxFiles != maxPutFiles || v.Put.PartBytes != partBytes || v.Call.MaxBody != maxCallBody {
		t.Fatalf("the vectors bound a put at %d bytes, %d files and %d bytes a part, and a call's body at %d; the driver at %d, %d, %d and %d",
			v.Put.MaxBytes, v.Put.MaxFiles, v.Put.PartBytes, v.Call.MaxBody, maxPutBytes, maxPutFiles, partBytes, maxCallBody)
	}
	part := map[string]any{"t": "part", "id": 1 << 53, "seq": 1 << 53, "part": strings.Repeat("A", 4*((partBytes+2)/3))}
	if body := len(must(json.Marshal(part))); body > maxToDriver {
		t.Fatalf("a part of the largest size holds %d bytes, past the driver's %d", body, maxToDriver)
	}
	call := callMessage{T: "call", ID: 1 << 53, Win: strings.Repeat("w", 256), Op: "action",
		Body: base64.StdEncoding.EncodeToString(make([]byte, maxCallBody))}
	if body := len(must(json.Marshal(call))); body > maxToHost {
		t.Fatalf("a call of the largest body holds %d bytes, past the host's %d", body, maxToHost)
	}
}

// Every message's example holds exactly its fields; the driver's own page
// messages marshal to their examples, field order included, and the
// host's parse to what they carry.
func TestPageMessages(t *testing.T) {
	v := loadFrameVectors(t)
	examples := map[string]string{}
	for name, m := range v.Messages {
		var example map[string]json.RawMessage
		if err := json.Unmarshal(m.Example, &example); err != nil {
			t.Fatalf("%s: its example is no object: %v", name, err)
		}
		keys := make([]string, 0, len(example))
		for key := range example {
			keys = append(keys, key)
		}
		if !reflect.DeepEqual(sorted(keys), sorted(m.Fields)) {
			t.Errorf("%s: its example holds %v, its fields are %v", name, keys, m.Fields)
		}
		var compact bytes.Buffer
		if err := json.Compact(&compact, m.Example); err != nil {
			t.Fatal(err)
		}
		examples[name] = compact.String()
	}
	for name, message := range map[string]any{
		"call": callMessage{T: "call", ID: 3, Win: "thr_01", Op: "invoke",
			Body: base64.StdEncoding.EncodeToString([]byte(`{"ref":"local.counter:0.1.0"}`))},
		"callend": callendMessage{T: "callend", ID: 3},
	} {
		if got := string(must(json.Marshal(message))); got != examples[name] {
			t.Errorf("%s: marshals to %s, want %s", name, got, examples[name])
		}
	}
	part, ok := parse([]byte(examples["part"]))
	if !ok || part.kind != "part" || part.id != 14 || part.seq != 0 || string(part.text) != "<!doctype html>" || part.failed {
		t.Errorf("the part's example parses to %+v", part)
	}
	got, ok := parse([]byte(examples["answer"]))
	if !ok || got.kind != "answer" || got.id != 3 || got.status != 200 || got.body != `{"ok":true}` {
		t.Errorf("the answer's example parses to %+v", got)
	}
	req, ok := parse([]byte(examples["req"]))
	if !ok || req.kind != "req" || req.req.Of != 0 {
		t.Errorf("the request's example parses to %+v", req)
	}
	put, ok := parse([]byte(`{"t":"req","id":14,"win":"thr_01","op":"page","of":3,"args":{}}`))
	if !ok || put.req.Of != 3 || put.req.Op != "page" {
		t.Errorf("a put's request parses to %+v", put)
	}
}

func sorted(list []string) []string {
	list = append([]string{}, list...)
	slices.Sort(list)
	return list
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
		"an image": imageMessage{T: "image", ID: 12, Seq: 3,
			JPEG: "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAABAAEBAREA/8QAFAABAAAAAAAAAAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AKp//2Q=="},
		"uncast": uncastMessage{T: "uncast", ID: 12},
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

// Every event the vectors accept is read, alone and as many as one message
// holds; every event they refuse is refused, and takes the message it is
// in with it; a message of no event, or of one past the bound, is refused.
func TestInputVectors(t *testing.T) {
	all := loadFrameVectors(t)
	if all.InFlight != castInputs {
		t.Fatalf("the vectors hold %d input messages of a cast on their way; the driver %d", all.InFlight, castInputs)
	}
	v := all.Input
	if v.MaxEvents != maxInputEvents || len(v.Accept) == 0 || len(v.Refuse) == 0 {
		t.Fatalf("the vectors bound a message at %d events, the driver at %d; %d accepted, %d refused",
			v.MaxEvents, maxInputEvents, len(v.Accept), len(v.Refuse))
	}
	list := func(events ...json.RawMessage) json.RawMessage { return must(json.Marshal(events)) }
	for _, c := range v.Accept {
		if _, ok := parseInput(list(c.Event)); !ok {
			t.Errorf("%s: refused, want accepted: %s", c.Name, c.Event)
		}
		if _, ok := parseInput(list(c.Event, v.Refuse[0].Event)); ok {
			t.Errorf("%s: a message with a refused event beside it was accepted", c.Name)
		}
	}
	for _, c := range v.Refuse {
		if _, ok := parseInput(list(c.Event)); ok {
			t.Errorf("%s: accepted, want refused: %s", c.Name, c.Event)
		}
	}
	most := make([]json.RawMessage, maxInputEvents+1)
	for i := range most {
		most[i] = v.Accept[i%len(v.Accept)].Event
	}
	if events, ok := parseInput(list(most[:maxInputEvents]...)); !ok || len(events) != maxInputEvents {
		t.Errorf("a message of %d events was refused", maxInputEvents)
	}
	if _, ok := parseInput(list(most...)); ok {
		t.Errorf("a message of %d events was accepted", maxInputEvents+1)
	}
	if _, ok := parseInput(list()); ok {
		t.Error("a message of no event was accepted")
	}
}
