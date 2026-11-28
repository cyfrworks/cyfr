// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package locusroles

import (
	"encoding/json"
	"reflect"
	"testing"

	"github.com/cyfr/locus/keeper/internal/wire/wirejson"
	"github.com/cyfr/locus/keeper/internal/wire/wiretest"
)

// The runtime row of tests/fixtures/locus_roles.json, found by its name
// and named once, is Runtime as encoding/json writes it under Role's own
// tags, compared as JSON trees whose numbers are kept as written: a member
// either has and the other lacks, a null for a value, a number of another
// spelling, or a name of another case fails. Prima's test holds the
// table's order and the other rows.
func TestTheRuntimeRoleIsTheTablesRow(t *testing.T) {
	var table struct {
		Roles []json.RawMessage `json:"roles"`
	}
	wiretest.Load(t, "locus_roles.json", &table)
	written, err := json.Marshal(Runtime)
	if err != nil {
		t.Fatal(err)
	}
	want, err := wirejson.Read(written)
	if err != nil {
		t.Fatal(err)
	}
	rows := 0
	for _, raw := range table.Roles {
		row, err := wirejson.Read(raw)
		if err != nil {
			t.Fatal(err)
		}
		if named, _ := row.(map[string]any); named["name"] != "runtime" {
			continue
		}
		rows++
		if !reflect.DeepEqual(row, want) {
			t.Errorf("the table's runtime row %s\nthe package's %s", raw, written)
		}
	}
	if rows != 1 {
		t.Fatalf("locus_roles.json names %d runtime rows", rows)
	}
	if Runtime.Memory.Unread != nil || Runtime.KeptRoot != nil || Runtime.GuestRoot != nil {
		t.Errorf("the runtime keeps no unread bound, no kept folders and no machines: %+v", Runtime)
	}
}
