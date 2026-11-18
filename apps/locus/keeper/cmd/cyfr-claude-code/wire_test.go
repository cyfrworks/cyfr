// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"
)

type wireVectors struct {
	Version      int                 `json:"version"`
	MaxLineBytes int                 `json:"max_line_bytes"`
	MaxIDBytes   int                 `json:"max_id_bytes"`
	MaxList      int                 `json:"max_list"`
	Config       map[string]string   `json:"config"`
	Counts       []string            `json:"counts"`
	Accountings  []string            `json:"accountings"`
	Stops        []string            `json:"stops"`
	Phases       []string            `json:"phases"`
	ErrorTypes   []string            `json:"error_types"`
	Blocks       []json.RawMessage   `json:"blocks"`
	MediaTypes   map[string][]string `json:"media_types"`
	Native       []string            `json:"native"`
	Commands     map[string]vector   `json:"commands"`
	Events       map[string]vector   `json:"events"`
	UUID         struct {
		Prefix string `json:"prefix"`
		Cases  []struct {
			ID   string `json:"id"`
			UUID string `json:"uuid"`
		} `json:"cases"`
	} `json:"uuid"`
	Read []struct {
		Name  string         `json:"name"`
		From  string         `json:"from"`
		Line  string         `json:"line"`
		Reads map[string]any `json:"reads"`
	} `json:"read"`
	Refuse []struct {
		Name      string `json:"name"`
		From      string `json:"from"`
		Line      string `json:"line"`
		LineBytes int    `json:"line_bytes"`
		Reason    string `json:"reason"`
	} `json:"refuse"`
}

type vector struct {
	Fields   []string          `json:"fields"`
	Optional []string          `json:"optional"`
	Types    map[string]string `json:"types"`
	Example  json.RawMessage   `json:"example"`
}

func loadWireVectors(t *testing.T) wireVectors {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "..", "..", "tests", "fixtures", "brain_wire.json"))
	if err != nil {
		t.Fatal(err)
	}
	var v wireVectors
	if err := json.Unmarshal(data, &v); err != nil {
		t.Fatal(err)
	}
	return v
}

var typeNames = map[fieldType]string{
	tID: "id", tString: "string", tCount: "count", tBoolean: "boolean", tObject: "object", tIDs: "ids",
	tStrings: "strings", tContent: "content", tTools: "tools", tConfig: "config", tCounts: "counts",
	tModels: "models", tModelCounts: "model_counts", tPhase: "phase", tErrorType: "error_type",
	tAccounting: "accounting", tStop: "stop",
}

func specOf(s spec) vector {
	types := map[string]string{}
	for name, ft := range s.types {
		types[name] = typeNames[ft]
	}
	optional := s.optional
	if optional == nil {
		optional = []string{}
	}
	return vector{Fields: s.fields, Optional: optional, Types: types}
}

func sorted(s []string) []string {
	out := append([]string{}, s...)
	sort.Strings(out)
	return out
}

func TestTheWiresBoundsAndVocabulariesAreTheVectors(t *testing.T) {
	v := loadWireVectors(t)
	if v.Version != wireVersion || v.MaxLineBytes != maxLineBytes || v.MaxIDBytes != maxIDBytes || v.MaxList != maxList {
		t.Fatalf("the vectors' version and bounds are %d, %d, %d, %d", v.Version, v.MaxLineBytes, v.MaxIDBytes, v.MaxList)
	}
	config := map[string]string{}
	for name, ft := range configTypes {
		config[name] = typeNames[ft]
	}
	if !reflect.DeepEqual(config, v.Config) || !reflect.DeepEqual(countNames, v.Counts) ||
		!reflect.DeepEqual(accountings, v.Accountings) || !reflect.DeepEqual(stops, v.Stops) ||
		!reflect.DeepEqual(phases, v.Phases) || !reflect.DeepEqual(errorTypes, v.ErrorTypes) ||
		!reflect.DeepEqual(mediaTypes, v.MediaTypes) || !reflect.DeepEqual(nativeEvents, v.Native) {
		t.Fatal("the configuration, counts, accountings, stops, phases, error types, media types and native events are the vectors'")
	}
	if v.UUID.Prefix != uuidPrefix {
		t.Fatalf("the uuid's prefix is the vectors': %q", v.UUID.Prefix)
	}
	for _, c := range v.UUID.Cases {
		if got := postUUID(c.ID); got != c.UUID {
			t.Fatalf("the uuid of %q is %s, the vectors say %s", c.ID, got, c.UUID)
		}
	}
	for _, block := range v.Blocks {
		if !blockOK(block) {
			t.Fatalf("every block the vectors show reads: %s", block)
		}
	}
}

func TestEveryMessageIsTheVectorsAndItsExampleReads(t *testing.T) {
	v := loadWireVectors(t)
	for direction, pair := range map[string]struct {
		ours   map[string]spec
		theirs map[string]vector
	}{"commands": {commands, v.Commands}, "events": {events, v.Events}} {
		if len(pair.ours) != len(pair.theirs) {
			t.Fatalf("the %s are the vectors' %d", direction, len(pair.theirs))
		}
		for name, s := range pair.ours {
			want, ok := pair.theirs[name]
			if !ok {
				t.Fatalf("the vectors name no %s %s", direction, name)
			}
			got := specOf(s)
			if !reflect.DeepEqual(got.Fields, want.Fields) || !reflect.DeepEqual(sorted(got.Optional), sorted(want.Optional)) || !reflect.DeepEqual(got.Types, want.Types) {
				t.Fatalf("%s %s is %v, the vectors' %v", direction, name, got, want)
			}
			if _, _, err := readLine(want.Example, pair.ours); err != nil {
				t.Fatalf("the example of %s %s reads (%v): %s", direction, name, err, want.Example)
			}
		}
	}
}

func TestTheVectorsLinesReadAsTheySay(t *testing.T) {
	v := loadWireVectors(t)
	of := map[string]map[string]spec{"holder": commands, "driver": events}
	for _, c := range v.Read {
		_, members, err := readLine([]byte(c.Line), of[c.From])
		if err != nil {
			t.Fatalf("%s: %v", c.Name, err)
		}
		got := map[string]any{}
		for name, raw := range members {
			var value any
			_ = json.Unmarshal(raw, &value)
			got[name] = value
		}
		if !reflect.DeepEqual(got, c.Reads) {
			t.Fatalf("%s reads as %v, the vectors say %v", c.Name, got, c.Reads)
		}
	}
	reasons := map[string]error{"unreadable": errUnreadable, "unknown": errUnknown, "too_large": errTooLarge}
	for _, c := range v.Refuse {
		line := []byte(c.Line)
		if c.LineBytes > 0 {
			prefix := `{"t":"said","gen":0,"message":"m","text":"`
			line = []byte(prefix + strings.Repeat("x", c.LineBytes-len(prefix)-2) + `"}`)
			if len(line) != c.LineBytes {
				t.Fatalf("%s is %d bytes", c.Name, len(line))
			}
		}
		if _, _, err := readLine(line, of[c.From]); !errors.Is(err, reasons[c.Reason]) {
			t.Fatalf("%s is refused %s: %v", c.Name, c.Reason, err)
		}
	}
}

func TestEveryEventTheDriverWritesReadsAsTheWires(t *testing.T) {
	// encodeEvent holds an event to the wire before it is written: one it
	// does not read is never written.
	if _, err := encodeEvent(newEvent("own").set("gen", 0).set("name", "Bash").set("phase", "running")); err == nil {
		t.Fatal("an event the wire does not read is not encoded")
	}
	line, err := encodeEvent(newEvent("accepted").set("id", "p<1>&"))
	if err != nil || string(line) != `{"t":"accepted","id":"p<1>&"}` {
		t.Fatalf("an event is written in its members' order, unescaped: %s %v", line, err)
	}
}
