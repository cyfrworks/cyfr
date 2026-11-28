// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package wiretest reads the vector files under tests/fixtures for the
// wire packages' tests, strictly: a case is decoded only when every
// member its reader needs is present, none is null where a value is due,
// and none is one its reader does not know, so a vector that drifts fails
// the test that reads it instead of reading as a zero.
package wiretest

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"
)

// Load decodes the named vector file, read from a wire package's
// directory, into v: a pointer to a struct of the sections its test reads,
// each a json.RawMessage tagged with the section's name.
func Load(t testing.TB, file string, v any) {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "..", "..", "..", "tests", "fixtures", file))
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(data, v); err != nil {
		t.Fatal(err)
	}
}

// Cases are the items of a list section, at least least of them.
func Cases(t testing.TB, raw json.RawMessage, least int) []json.RawMessage {
	t.Helper()
	var cases []json.RawMessage
	if err := json.Unmarshal(raw, &cases); err != nil {
		t.Fatal(err)
	}
	if len(cases) < least {
		t.Fatalf("%d cases, fewer than %d", len(cases), least)
	}
	return cases
}

// Decode decodes one case into v, a pointer to a struct whose fields are
// the case's members, exactly: a member is matched by its tag's exact
// spelling and one v has no field for fails; each of required must be
// present, and no present member may be null but those nullable names; a
// field's JSON type must be its own, so a number is never taken from a
// string. A nested object's members are held the same way, every one
// present, and null only where its field is a pointer or raw JSON.
func Decode(t testing.TB, raw json.RawMessage, v any, required []string, nullable ...string) {
	t.Helper()
	target := reflect.TypeOf(v)
	if target.Kind() != reflect.Pointer || target.Elem().Kind() != reflect.Struct {
		t.Fatalf("wiretest.Decode takes a pointer to a struct, not %s", target)
	}
	mayBeNull := map[string]bool{}
	for _, n := range nullable {
		mayBeNull[n] = true
	}
	if why := exact(raw, target.Elem(), required, mayBeNull); why != "" {
		t.Fatalf("%s: %s", why, raw)
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	if err := decoder.Decode(v); err != nil {
		t.Fatalf("%v: %s", err, raw)
	}
}

// fields are a struct's fields by their tags' exact names, an embedded
// struct's among them.
func fields(st reflect.Type) map[string]reflect.Type {
	out := map[string]reflect.Type{}
	for _, f := range named(st) {
		out[jsonName(f)] = f.Type
	}
	return out
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
			out = append(out, named(f.Type)...)
		case name != "" && name != "-":
			out = append(out, f)
		}
	}
	return out
}

// exact is why raw is not an object of st's members as the rules of
// Decode say, or "" for one that is.
func exact(raw json.RawMessage, st reflect.Type, required []string, mayBeNull map[string]bool) string {
	var members map[string]json.RawMessage
	if err := json.Unmarshal(raw, &members); err != nil || members == nil {
		return "a case that is no object"
	}
	known := fields(st)
	for name := range members {
		if _, ok := known[name]; !ok {
			return "a member its reader has not, " + strconv.Quote(name)
		}
	}
	for _, name := range required {
		if _, present := members[name]; !present {
			return "a case without its " + name
		}
	}
	for name, value := range members {
		if why := typed(value, known[name], mayBeNull[name]); why != "" {
			return name + ": " + why
		}
	}
	return ""
}

var rawType = reflect.TypeOf(json.RawMessage(nil))
var numberType = reflect.TypeOf(json.Number(""))

// typed is why value is not of the JSON type of a field of type ft, or "".
func typed(value json.RawMessage, ft reflect.Type, mayBeNull bool) string {
	trimmed := bytes.TrimSpace(value)
	if string(trimmed) == "null" {
		if mayBeNull {
			return ""
		}
		return "null where a value is due"
	}
	if ft == rawType {
		return ""
	}
	if ft.Kind() == reflect.Pointer {
		ft = ft.Elem()
	}
	first := trimmed[0]
	switch {
	case ft == numberType, ft.Kind() >= reflect.Int && ft.Kind() <= reflect.Float64:
		if first != '-' && (first < '0' || first > '9') {
			return "no number"
		}
	case ft.Kind() == reflect.String:
		if first != '"' {
			return "no text"
		}
	case ft.Kind() == reflect.Bool:
		if string(trimmed) != "true" && string(trimmed) != "false" {
			return "no boolean"
		}
	case ft.Kind() == reflect.Slice && ft.Elem().Kind() == reflect.Uint8:
		// Bytes are their base64 text.
		if first != '"' {
			return "no text"
		}
	case ft.Kind() == reflect.Slice:
		if first != '[' {
			return "no list"
		}
		if el := ft.Elem(); el.Kind() == reflect.Struct || (el.Kind() == reflect.Pointer && el.Elem().Kind() == reflect.Struct) {
			var items []json.RawMessage
			_ = json.Unmarshal(trimmed, &items)
			for _, item := range items {
				if why := typed(item, el, false); why != "" {
					return why
				}
			}
		}
	case ft.Kind() == reflect.Map:
		if first != '{' {
			return "no object"
		}
	case ft.Kind() == reflect.Struct:
		return nested(trimmed, ft)
	}
	return ""
}

// nested holds a nested object to its struct: every member present, null
// only where the field is a pointer or raw JSON, which its test reads.
func nested(raw json.RawMessage, st reflect.Type) string {
	required := []string{}
	mayBeNull := map[string]bool{}
	for _, f := range named(st) {
		name := jsonName(f)
		required = append(required, name)
		mayBeNull[name] = f.Type.Kind() == reflect.Pointer || f.Type == rawType
	}
	return exact(raw, st, required, mayBeNull)
}

// LoadStrict decodes the named vector file into v, a pointer to a struct
// of the sections its test reads, and holds every section to v's types as
// Decode holds a case, at every level: each section v names present; in
// each case a member matched by its tag's exact spelling, none v has no
// field for, each non-pointer member present but one tagged
// wire:"optional", a pointer member absent or a value but one tagged
// wire:"required", and null only where a field is tagged wire:"null" or
// is raw JSON; a field's JSON type its own.
func LoadStrict(t testing.TB, file string, v any) {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "..", "..", "..", "tests", "fixtures", file))
	if err != nil {
		t.Fatal(err)
	}
	target := reflect.TypeOf(v)
	if target.Kind() != reflect.Pointer || target.Elem().Kind() != reflect.Struct {
		t.Fatalf("wiretest.LoadStrict takes a pointer to a struct, not %s", target)
	}
	var top map[string]json.RawMessage
	if err := json.Unmarshal(data, &top); err != nil {
		t.Fatal(err)
	}
	st := target.Elem()
	for i := 0; i < st.NumField(); i++ {
		f := st.Field(i)
		name, _, _ := strings.Cut(f.Tag.Get("json"), ",")
		if name == "" || name == "-" {
			continue
		}
		raw, present := top[name]
		if !present {
			t.Fatalf("%s has no %s", file, name)
		}
		if why := walk(raw, f.Type, f.Tag.Get("wire")); why != "" {
			t.Fatalf("%s's %s: %s", file, name, why)
		}
	}
	if err := json.Unmarshal(data, v); err != nil {
		t.Fatal(err)
	}
}

// walk is why value is not of type ft as LoadStrict reads it, or "".
func walk(value json.RawMessage, ft reflect.Type, tag string) string {
	trimmed := bytes.TrimSpace(value)
	if string(trimmed) == "null" {
		if ft == rawType || strings.Contains(tag, "null") {
			return ""
		}
		return "null where a value is due"
	}
	if ft.Kind() == reflect.Pointer {
		ft = ft.Elem()
	}
	switch {
	case ft.Kind() == reflect.Struct:
		var members map[string]json.RawMessage
		if err := json.Unmarshal(trimmed, &members); err != nil || members == nil {
			return "no object: " + string(trimmed)
		}
		known := map[string]reflect.StructField{}
		for _, f := range named(ft) {
			name := jsonName(f)
			known[name] = f
			_, present := members[name]
			tag := f.Tag.Get("wire")
			optional := (f.Type.Kind() == reflect.Pointer && !strings.Contains(tag, "required")) || strings.Contains(tag, "optional")
			if !present && !optional {
				return "a case without its " + name + ": " + string(trimmed)
			}
		}
		for name, member := range members {
			f, ok := known[name]
			if !ok {
				return "a member its reader has not, " + strconv.Quote(name) + ": " + string(trimmed)
			}
			if why := walk(member, f.Type, f.Tag.Get("wire")); why != "" {
				return name + ": " + why
			}
		}
		return ""
	case ft.Kind() == reflect.Slice && ft.Elem().Kind() != reflect.Uint8 && ft != rawType:
		var items []json.RawMessage
		if err := json.Unmarshal(trimmed, &items); err != nil {
			return "no list"
		}
		for _, item := range items {
			if why := walk(item, ft.Elem(), ""); why != "" {
				return why
			}
		}
		return ""
	case ft.Kind() == reflect.Map:
		var items map[string]json.RawMessage
		if err := json.Unmarshal(trimmed, &items); err != nil {
			return "no object"
		}
		for _, item := range items {
			if why := walk(item, ft.Elem(), ""); why != "" {
				return why
			}
		}
		return ""
	}
	return typed(trimmed, ft, false)
}
