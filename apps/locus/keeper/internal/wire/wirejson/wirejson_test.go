// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package wirejson

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"math"
	"math/big"
	"reflect"
	"strconv"
	"strings"
	"testing"

	"github.com/cyfr/locus/keeper/internal/wire/wiretest"
)

// A read document, its value, and Go's own answer where the two ends
// differ, as the vector states it.
type readCase struct {
	Why   string          `json:"why"`
	Doc   string          `json:"doc_b64"`
	Value json.RawMessage `json:"value"`
	Go    string          `json:"go" wire:"optional"`
}

// A refused document.
type refusedCase struct {
	Why string `json:"why"`
	Doc string `json:"doc_b64"`
}

// A value written, its bytes, and Go's own answer where the two ends
// differ.
type writeCase struct {
	Why       string `json:"why"`
	ValueJSON string `json:"value_json"`
	Bytes     string `json:"bytes_b64"`
	Go        string `json:"go" wire:"optional"`
}

// wireVectors is tests/fixtures/wire_json.json, which Prima's test holds
// Jason and Elixir's Base to; its base64 sections are package
// macenvelope's.
type wireVectors struct {
	Version         int           `json:"version"`
	MaxIntegerChars int           `json:"max_integer_chars"`
	Reads           []readCase    `json:"reads"`
	Refused         []refusedCase `json:"refused"`
	Writes          []writeCase   `json:"writes"`
}

func vectors(t *testing.T) wireVectors {
	t.Helper()
	var v wireVectors
	wiretest.LoadStrict(t, "wire_json.json", &v)
	if v.Version != 1 {
		t.Fatalf("the vector file's version %d", v.Version)
	}
	return v
}

// same is whether a and b are one value as Prima compares what it read: an
// integer equal to an integer, a float to a float, each member and item
// alike.
// float is the number a float's text is as Jason reads it: the text
// parsed whole, but for a zero with an exponent and no fraction, which
// Jason reads as 0.0 whatever its sign ("-0e5" is 0.0, where "-0.0e5" and
// "-1e-400" are -0.0). No wire of the protocol reads a float: the vectors
// compare the floats Prima reads.
func float(n Number) (float64, bool) {
	text := string(n)
	mantissa, _, exponent := strings.Cut(strings.ToLower(text), "e")
	if exponent && strings.TrimPrefix(mantissa, "-") == "0" {
		return 0, true
	}
	f, err := strconv.ParseFloat(text, 64)
	return f, err == nil
}

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
		x, okA := float(a)
		y, okB := float(b)
		return okA && okB && x == y && math.Signbit(x) == math.Signbit(y)
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
	if len(reads) < 25 {
		t.Fatalf("%d reads", len(reads))
	}
	differences := 0
	for _, c := range reads {
		doc, _ := base64.StdEncoding.DecodeString(c.Doc)
		got, err := Read(doc)
		switch c.Go {
		case "too_deep":
			differences++
			if !errors.Is(err, ErrTooDeep) {
				t.Errorf("%s: %v; Go refuses it too_deep", c.Why, err)
			}
		case "":
			want, werr := Read(c.Value)
			if err != nil || werr != nil || !same(got, want) {
				t.Errorf("%s: %#v, %v; want %s", c.Why, got, err, c.Value)
			}
		default:
			t.Errorf("%s: no Go answer %q", c.Why, c.Go)
		}
	}
	if differences == 0 {
		t.Error("no read case states the depth the two ends differ at")
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
	writes := vectors(t).Writes
	if len(writes) < 14 {
		t.Fatalf("%d writes", len(writes))
	}
	refused := 0
	for _, c := range writes {
		v, err := Read([]byte(c.ValueJSON))
		if err != nil {
			t.Fatalf("%s: %v", c.Why, err)
		}
		want, _ := base64.StdEncoding.DecodeString(c.Bytes)
		got, err := Write(v)
		switch c.Go {
		case "unwritable":
			refused++
			if !errors.Is(err, ErrUnwritable) {
				t.Errorf("%s: written as %q; Go refuses it", c.Why, got)
			}
		case "":
			if err != nil || string(got) != string(want) {
				t.Errorf("%s: %q, %v; want %q", c.Why, got, err, want)
			}
		default:
			t.Errorf("%s: no Go answer %q", c.Why, c.Go)
		}
	}
	if refused == 0 {
		t.Error("no write case states what Go refuses to write")
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
