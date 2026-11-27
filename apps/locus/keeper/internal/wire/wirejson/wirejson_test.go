// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package wirejson

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"math"
	"math/big"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"
)

type wireCase struct {
	Why   string          `json:"why"`
	Doc   string          `json:"doc_b64"`
	Value json.RawMessage `json:"value"`
	Bytes string          `json:"bytes_b64"`
}

// wireVectors is tests/fixtures/wire_json.json, which Prima's test holds
// Jason and Elixir's Base to; its base64 sections are package
// macenvelope's.
type wireVectors struct {
	Version         int        `json:"version"`
	MaxIntegerChars int        `json:"max_integer_chars"`
	Reads           []wireCase `json:"reads"`
	Refused         []wireCase `json:"refused"`
	Writes          []wireCase `json:"writes"`
}

func vectors(t *testing.T) wireVectors {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "..", "..", "..", "tests", "fixtures", "wire_json.json"))
	if err != nil {
		t.Fatal(err)
	}
	var v wireVectors
	if err := json.Unmarshal(data, &v); err != nil || v.Version != 1 {
		t.Fatalf("the vector file: %v, version %d", err, v.Version)
	}
	return v
}

// same is whether a and b are one value as Prima compares what it read: an
// integer equal to an integer, a float to a float, each member and item
// alike.
func same(a, b any) bool {
	switch a := a.(type) {
	case Number:
		b, ok := b.(Number)
		if !ok || a.Integer() != b.Integer() {
			return false
		}
		if a.Integer() {
			x, _ := new(big.Int).SetString(string(a), 10)
			y, _ := new(big.Int).SetString(string(b), 10)
			return x.Cmp(y) == 0
		}
		x, _ := strconv.ParseFloat(string(a), 64)
		y, _ := strconv.ParseFloat(string(b), 64)
		return x == y && math.Signbit(x) == math.Signbit(y)
	case []any:
		b, ok := b.([]any)
		if !ok || len(a) != len(b) {
			return false
		}
		for i := range a {
			if !same(a[i], b[i]) {
				return false
			}
		}
		return true
	case map[string]any:
		b, ok := b.(map[string]any)
		if !ok || len(a) != len(b) {
			return false
		}
		for k, v := range a {
			if w, has := b[k]; !has || !same(v, w) {
				return false
			}
		}
		return true
	default:
		return reflect.DeepEqual(a, b)
	}
}

func TestEveryDocumentReadsAsPrimasReaderReadsIt(t *testing.T) {
	reads := vectors(t).Reads
	if len(reads) < 20 {
		t.Fatalf("%d reads", len(reads))
	}
	for _, c := range reads {
		doc, _ := base64.StdEncoding.DecodeString(c.Doc)
		got, err := Read(doc)
		want, werr := Read(c.Value)
		if err != nil || werr != nil || !same(got, want) {
			t.Errorf("%s: %#v, %v; want %s", c.Why, got, err, c.Value)
		}
	}
	if n := vectors(t).MaxIntegerChars; n != maxIntegerText {
		t.Errorf("the vector's longest integer is %d characters, the reader's %d", n, maxIntegerText)
	}
}

func TestEveryRefusedDocumentIsRefused(t *testing.T) {
	refused := vectors(t).Refused
	if len(refused) < 35 {
		t.Fatalf("%d refused", len(refused))
	}
	for _, c := range refused {
		doc, _ := base64.StdEncoding.DecodeString(c.Doc)
		if got, err := Read(doc); !errors.Is(err, ErrMalformed) {
			t.Errorf("%s: %#v, %v; want malformed", c.Why, got, err)
		}
	}
}

func TestEveryValueIsWrittenAsPrimasWriterWritesIt(t *testing.T) {
	for _, c := range vectors(t).Writes {
		v, err := Read(c.Value)
		if err != nil {
			t.Fatal(err)
		}
		want, _ := base64.StdEncoding.DecodeString(c.Bytes)
		if got, err := Write(v); err != nil || string(got) != string(want) {
			t.Errorf("%s: %q, %v; want %q", c.Why, got, err, want)
		}
	}
}

// The depth is counted before the parser reads, strings skipped, so a
// bracket inside a string is no level.
func TestADocumentPastTheDepthIsRefusedBeforeItIsRead(t *testing.T) {
	at := strings.Repeat("[", MaxDepth) + strings.Repeat("]", MaxDepth)
	if _, err := Read([]byte(at)); err != nil {
		t.Fatalf("at the depth: %v", err)
	}
	past := strings.Repeat("[", MaxDepth+1) + strings.Repeat("]", MaxDepth+1)
	if _, err := Read([]byte(past)); !errors.Is(err, ErrTooDeep) {
		t.Fatalf("past the depth: %v", err)
	}
	if _, err := Read([]byte(`"` + strings.Repeat("[", MaxDepth+1) + `"`)); err != nil {
		t.Fatalf("brackets in a string: %v", err)
	}
	if got := Depth([]byte(`["\"[[", {"a":[]}]`)); got != 3 {
		t.Fatalf("an escaped quote ends no string: depth %d", got)
	}
}

func TestAnIntegerReadsWithinItsRange(t *testing.T) {
	for _, c := range []struct {
		v    any
		max  uint64
		n    uint64
		read bool
	}{
		{Number("0"), 10, 0, true},
		{Number("-0"), 10, 0, true},
		{Number("10"), 10, 10, true},
		{Number("11"), 10, 0, false},
		{Number("-1"), 10, 0, false},
		{Number("1.0"), 10, 0, false},
		{Number("1e1"), 100, 0, false},
		{Number("9007199254740991"), MaxSafeInteger, MaxSafeInteger, true},
		{Number("9007199254740992"), MaxSafeInteger, 0, false},
		{Number("18446744073709551616"), ^uint64(0), 0, false},
		{Number(strings.Repeat("9", 1024)), ^uint64(0), 0, false},
		{"1", 10, 0, false},
		{nil, 10, 0, false},
	} {
		if n, ok := Uint(c.v, c.max); n != c.n || ok != c.read {
			t.Errorf("Uint(%#v, %d) = %d, %v", c.v, c.max, n, ok)
		}
	}
	if !(Number("-0").Negative() == false && Number("-1").Negative() && Number("-0.0").Negative() == false &&
		Number("-0.1").Negative() && Number("-0e5").Negative() == false) {
		t.Fatal("the sign of a number")
	}
}

// Write refuses what Prima's writer would write otherwise or not at all.
func TestAValueWriteCannotSpellAsPrimaIsRefused(t *testing.T) {
	if got, err := Write(Ordered{{"v", 3}, {"ok", nil}}); err != nil || string(got) != `{"v":3,"ok":null}` {
		t.Errorf("an ordered object: %s, %v", got, err)
	}
	big := map[string]any{}
	for i := 0; i < 33; i++ {
		big[strings.Repeat("a", i+1)] = i
	}
	for _, v := range []any{"\xff", big, 1.5, Number("01"), Number(""), struct{}{}} {
		if got, err := Write(v); !errors.Is(err, ErrUnwritable) {
			t.Errorf("Write(%#v) = %s, %v; want unwritable", v, got, err)
		}
	}
}
