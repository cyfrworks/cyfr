// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package ops

import (
	"encoding/json"
	"testing"
)

func TestFieldPreservesPresence(t *testing.T) {
	type input struct {
		Count    Field[int]      `json:"count,omitzero"`
		Enabled  Field[bool]     `json:"enabled,omitzero"`
		Name     Field[string]   `json:"name,omitzero"`
		Nullable Field[*string]  `json:"nullable,omitzero"`
		Items    Field[[]string] `json:"items,omitzero"`
	}
	for _, tc := range []struct {
		value input
		want  string
	}{
		{input{}, `{}`},
		{input{Count: Value(0), Enabled: Value(false), Name: Value("")}, `{"count":0,"enabled":false,"name":""}`},
		{input{Nullable: Null[string]()}, `{"nullable":null}`},
		{input{Nullable: Nullable("")}, `{"nullable":""}`},
		{input{Items: Value([]string{})}, `{"items":[]}`},
	} {
		encoded, err := json.Marshal(tc.value)
		if err != nil || string(encoded) != tc.want {
			t.Fatalf("got %s, %v; want %s", encoded, err, tc.want)
		}
		var decoded input
		if err := json.Unmarshal(encoded, &decoded); err != nil {
			t.Fatal(err)
		}
		roundtrip, err := json.Marshal(decoded)
		if err != nil || string(roundtrip) != tc.want {
			t.Fatalf("roundtrip got %s, %v", roundtrip, err)
		}
	}
	var decoded input
	if err := json.Unmarshal([]byte(`{"count":null}`), &decoded); err == nil {
		t.Fatal("null became zero")
	}
}

func TestDecodeRecordRejectsLostPresenceAndUnknownKeys(t *testing.T) {
	type record struct {
		Count   int         `json:"count"`
		Label   *string     `json:"label"`
		Enabled Field[bool] `json:"enabled,omitzero"`
	}
	for _, raw := range []string{`null`, `{}`, `{"count":null,"label":null}`, `{"count":0}`, `{"count":0,"label":null,"extra":1}`} {
		var target record
		if err := decodeRecord([]byte(raw), &target); err == nil {
			t.Fatalf("accepted %s", raw)
		}
	}
	var target record
	if err := decodeRecord([]byte(`{"count":0,"label":null,"enabled":false}`), &target); err != nil {
		t.Fatal(err)
	}
	if target.Enabled.IsZero() {
		t.Fatal("explicit false was lost")
	}
}
