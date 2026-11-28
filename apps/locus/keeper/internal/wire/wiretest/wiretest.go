// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package wiretest reads the vector files under tests/fixtures for the
// wire packages' tests, strictly and at every level: a value is decoded
// only when the whole of its JSON is of the type its test compares it as,
// so a vector that drifts fails the test that reads it instead of reading
// as a zero.
//
// One walk holds every level to its Go type. An object read as a struct
// has exactly the struct's members, each matched by its tag's exact
// spelling (encoding/json matches names without regard to case); a list
// has every item of its element type, a fixed-length one exactly its
// length; an object read as a map has every value of the map's type; a
// number, text or boolean is that JSON type, so a number is never taken
// from a string; bytes are their base64 text. Null is refused where a
// value is due, a list's items and a map's values among them. Raw JSON
// is taken whole: a member its test does not read, or one it reads again
// through this package or compares by its bytes. A Go type the walk has
// no rule for fails the test, so no level is passed over.
//
// A struct field's tag says where its member may be absent or null: a
// non-pointer member is present but one tagged wire:"optional"; a pointer
// member may be absent but one tagged wire:"required"; null is allowed
// where a field is tagged wire:"null" or is raw JSON. Decode gives a
// case's own members these rules by its arguments in place of tags.
//
// What a test compares is decoded from the bytes the walk held, section
// by section, never from the whole file again, and a member name given
// twice in one object, anywhere in a vector file, fails its load: Prima's
// reader takes the first, encoding/json the last.
package wiretest

import (
	"bytes"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"sort"
	"strconv"
	"strings"
	"testing"
)

// Load decodes the named vector file, read from a wire package's
// directory, into v, a pointer to a struct of the sections its test reads:
// each section v names is present, held to its field's type at every
// level, and decoded from its own bytes. A section v does not name is
// passed over, for a file holds the sections of many readers, but no
// object anywhere in the file names a member twice.
func Load(t testing.TB, file string, v any) {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "..", "..", "..", "tests", "fixtures", file))
	if err != nil {
		t.Fatal(err)
	}
	st := structOf(t, "Load", v)
	if why := repeated(data); why != "" {
		t.Fatalf("%s: %s", file, why)
	}
	var top map[string]json.RawMessage
	if err := json.Unmarshal(data, &top); err != nil || top == nil {
		t.Fatalf("%s is no object: %v", file, err)
	}
	target := reflect.ValueOf(v).Elem()
	for _, f := range named(st) {
		name := jsonName(f)
		raw, present := top[name]
		if !present {
			t.Fatalf("%s has no %s", file, name)
		}
		if why := walk(raw, f.Type, tagged(f).null); why != "" {
			t.Fatalf("%s's %s: %s", file, name, why)
		}
		decode(t, raw, target.FieldByIndex(f.Index).Addr().Interface())
	}
}

// repeated is why data names a member twice in one object, at any level,
// or "".
func repeated(data []byte) string {
	type object struct {
		seen    map[string]bool
		wantKey bool
	}
	// open holds, for each list or object the tokens are inside, its
	// object, or nil for a list.
	var open []*object
	ended := func() {
		if n := len(open); n > 0 && open[n-1] != nil {
			open[n-1].wantKey = true
		}
	}
	d := json.NewDecoder(bytes.NewReader(data))
	d.UseNumber()
	for {
		tok, err := d.Token()
		if err == io.EOF {
			return ""
		}
		if err != nil {
			return "no JSON: " + err.Error()
		}
		if n := len(open); n > 0 && open[n-1] != nil && open[n-1].wantKey {
			if tok == json.Delim('}') {
				open = open[:n-1]
				ended()
				continue
			}
			name, _ := tok.(string)
			if open[n-1].seen[name] {
				return "a member named twice in one object, " + strconv.Quote(name)
			}
			open[n-1].seen[name] = true
			open[n-1].wantKey = false
			continue
		}
		switch tok {
		case json.Delim('{'):
			open = append(open, &object{seen: map[string]bool{}, wantKey: true})
			continue
		case json.Delim('['):
			open = append(open, nil)
			continue
		case json.Delim(']'):
			open = open[:len(open)-1]
		}
		ended()
	}
}

// Cases are the items of a list section, at least least of them.
func Cases(t testing.TB, raw json.RawMessage, least int) []json.RawMessage {
	t.Helper()
	var cases []json.RawMessage
	Value(t, raw, &cases)
	if len(cases) < least {
		t.Fatalf("%d cases, fewer than %d", len(cases), least)
	}
	return cases
}

// Value decodes raw into v, a pointer to any type the walk has a rule
// for, holding the whole of raw to v's type at every level.
func Value(t testing.TB, raw json.RawMessage, v any) {
	t.Helper()
	target := reflect.TypeOf(v)
	if target == nil || target.Kind() != reflect.Pointer {
		t.Fatalf("wiretest.Value takes a pointer, not %v", target)
	}
	if why := walk(raw, target.Elem(), false); why != "" {
		t.Fatalf("%s: %s", why, raw)
	}
	decode(t, raw, v)
}

// Decode decodes one case into v, a pointer to a struct whose fields are
// the case's members, as Value does, its own members' rules given here in
// place of tags: each of required is present, and only those nullable
// may be null. The members of an object within it are held by their
// fields' tags.
func Decode(t testing.TB, raw json.RawMessage, v any, required []string, nullable ...string) {
	t.Helper()
	st := structOf(t, "Decode", v)
	rule := func(f reflect.StructField) rules {
		name := jsonName(f)
		return rules{optional: !slices.Contains(required, name), null: slices.Contains(nullable, name)}
	}
	if why := object(bytes.TrimSpace(raw), st, rule); why != "" {
		t.Fatalf("%s: %s", why, raw)
	}
	decode(t, raw, v)
}

func structOf(t testing.TB, caller string, v any) reflect.Type {
	t.Helper()
	target := reflect.TypeOf(v)
	if target == nil || target.Kind() != reflect.Pointer || target.Elem().Kind() != reflect.Struct {
		t.Fatalf("wiretest.%s takes a pointer to a struct, not %v", caller, target)
	}
	return target.Elem()
}

func decode(t testing.TB, raw []byte, v any) {
	t.Helper()
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	if err := decoder.Decode(v); err != nil {
		t.Fatalf("%v: %s", err, raw)
	}
}

// rules are where a struct field's member may be absent or null.
type rules struct{ optional, null bool }

// tagged are a field's rules by its wire tag.
func tagged(f reflect.StructField) rules {
	tags := strings.Split(f.Tag.Get("wire"), ",")
	pointer := f.Type.Kind() == reflect.Pointer
	return rules{
		optional: slices.Contains(tags, "optional") || (pointer && !slices.Contains(tags, "required")),
		null:     slices.Contains(tags, "null") || f.Type == rawType,
	}
}

func jsonName(f reflect.StructField) string {
	name, _, _ := strings.Cut(f.Tag.Get("json"), ",")
	return name
}

// named are a struct's fields that a JSON member names, an embedded
// struct's fields in its place.
func named(st reflect.Type) []reflect.StructField {
	var out []reflect.StructField
	for i := 0; i < st.NumField(); i++ {
		f := st.Field(i)
		switch name := jsonName(f); {
		case f.Anonymous && name == "" && f.Type.Kind() == reflect.Struct:
			for _, inner := range named(f.Type) {
				inner.Index = append(append([]int{}, f.Index...), inner.Index...)
				out = append(out, inner)
			}
		case name != "" && name != "-":
			out = append(out, f)
		}
	}
	return out
}

var rawType = reflect.TypeOf(json.RawMessage(nil))
var numberType = reflect.TypeOf(json.Number(""))

// walk is why value is not of type ft at every level, or "": null only
// where mayBeNull says.
func walk(value []byte, ft reflect.Type, mayBeNull bool) string {
	trimmed := bytes.TrimSpace(value)
	if len(trimmed) == 0 {
		return "no value"
	}
	if string(trimmed) == "null" {
		if mayBeNull {
			return ""
		}
		return "null where a value is due"
	}
	if ft == rawType {
		return ""
	}
	first := trimmed[0]
	switch ft.Kind() {
	case reflect.Pointer:
		return walk(trimmed, ft.Elem(), false)
	case reflect.Struct:
		return object(trimmed, ft, tagged)
	case reflect.Slice, reflect.Array:
		if ft.Kind() == reflect.Slice && ft.Elem().Kind() == reflect.Uint8 {
			// Bytes are their base64 text.
			return kind(first == '"', "no text")
		}
		var items []json.RawMessage
		if first != '[' || json.Unmarshal(trimmed, &items) != nil {
			return "no list"
		}
		if ft.Kind() == reflect.Array && len(items) != ft.Len() {
			return strconv.Itoa(len(items)) + " items where " + strconv.Itoa(ft.Len()) + " are due"
		}
		for i, item := range items {
			if why := walk(item, ft.Elem(), false); why != "" {
				return "[" + strconv.Itoa(i) + "]: " + why
			}
		}
		return ""
	case reflect.Map:
		if ft.Key().Kind() != reflect.String {
			return "a map keyed by " + ft.Key().String() + ", which wiretest does not read"
		}
		var items map[string]json.RawMessage
		if first != '{' || json.Unmarshal(trimmed, &items) != nil {
			return "no object"
		}
		for _, name := range sortedKeys(items) {
			if why := walk(items[name], ft.Elem(), false); why != "" {
				return strconv.Quote(name) + ": " + why
			}
		}
		return ""
	case reflect.String:
		if ft == numberType {
			return kind(first == '-' || (first >= '0' && first <= '9'), "no number")
		}
		return kind(first == '"', "no text")
	case reflect.Bool:
		return kind(string(trimmed) == "true" || string(trimmed) == "false", "no boolean")
	case reflect.Int, reflect.Int8, reflect.Int16, reflect.Int32, reflect.Int64,
		reflect.Uint, reflect.Uint8, reflect.Uint16, reflect.Uint32, reflect.Uint64,
		reflect.Float32, reflect.Float64:
		return kind(first == '-' || (first >= '0' && first <= '9'), "no number")
	}
	return "a value of " + ft.String() + ", which wiretest does not read"
}

func kind(ok bool, why string) string {
	if ok {
		return ""
	}
	return why
}

// object is why raw is not an object of st's members, each by rule, or "".
func object(raw []byte, st reflect.Type, rule func(reflect.StructField) rules) string {
	var members map[string]json.RawMessage
	if len(raw) == 0 || raw[0] != '{' || json.Unmarshal(raw, &members) != nil {
		return "no object"
	}
	known := map[string]reflect.StructField{}
	for _, f := range named(st) {
		name := jsonName(f)
		known[name] = f
		if _, present := members[name]; !present && !rule(f).optional {
			return "without its " + name
		}
	}
	for _, name := range sortedKeys(members) {
		f, ok := known[name]
		if !ok {
			return "a member its reader has not, " + strconv.Quote(name)
		}
		if why := walk(members[name], f.Type, rule(f).null); why != "" {
			return name + ": " + why
		}
	}
	return ""
}

func sortedKeys(m map[string]json.RawMessage) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}
