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
// the case's members: each of required must be present and not null but
// those in nullable, and a member v has no field for fails.
func Decode(t testing.TB, raw json.RawMessage, v any, required []string, nullable ...string) {
	t.Helper()
	var members map[string]json.RawMessage
	if err := json.Unmarshal(raw, &members); err != nil {
		t.Fatalf("a case that is no object: %s", raw)
	}
	mayBeNull := map[string]bool{}
	for _, n := range nullable {
		mayBeNull[n] = true
	}
	for _, name := range required {
		value, present := members[name]
		switch {
		case !present:
			t.Fatalf("a case without its %s: %s", name, raw)
		case string(value) == "null" && !mayBeNull[name]:
			t.Fatalf("a case whose %s is null: %s", name, raw)
		}
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	decoder.UseNumber()
	if err := decoder.Decode(v); err != nil {
		t.Fatalf("%v: %s", err, raw)
	}
}
