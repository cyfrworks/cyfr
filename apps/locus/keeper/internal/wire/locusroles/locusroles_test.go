// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package locusroles

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

// The runtime row of tests/fixtures/locus_roles.json, read strictly into
// Role: a member Role lacks, or one it has that the row lacks, fails.
func runtimeRow(t *testing.T) Role {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "..", "..", "..", "tests", "fixtures", "locus_roles.json"))
	if err != nil {
		t.Fatal(err)
	}
	var table struct {
		Roles []json.RawMessage `json:"roles"`
	}
	if err := json.Unmarshal(data, &table); err != nil {
		t.Fatal(err)
	}
	for _, raw := range table.Roles {
		var named struct {
			Name string `json:"name"`
		}
		if err := json.Unmarshal(raw, &named); err != nil {
			t.Fatal(err)
		}
		if named.Name != "runtime" {
			continue
		}
		var members map[string]json.RawMessage
		if err := json.Unmarshal(raw, &members); err != nil {
			t.Fatal(err)
		}
		if n := reflect.TypeOf(Role{}).NumField(); len(members) != n {
			t.Fatalf("the runtime row has %d members, Role %d", len(members), n)
		}
		var memory map[string]json.RawMessage
		if err := json.Unmarshal(members["memory"], &memory); err != nil {
			t.Fatal(err)
		}
		if n := reflect.TypeOf(Memory{}).NumField(); len(memory) != n {
			t.Fatalf("the runtime row's memory has %d members, Memory %d", len(memory), n)
		}
		var role Role
		decoder := json.NewDecoder(bytes.NewReader(raw))
		decoder.DisallowUnknownFields()
		if err := decoder.Decode(&role); err != nil {
			t.Fatal(err)
		}
		return role
	}
	t.Fatal("locus_roles.json names no runtime role")
	return Role{}
}

func TestTheRuntimeRoleIsTheTablesRow(t *testing.T) {
	row := runtimeRow(t)
	if !reflect.DeepEqual(row, Runtime) {
		t.Errorf("the table's runtime row %+v\nthe package's %+v", row, Runtime)
	}
	if row.Memory.Unread != nil || row.KeptRoot != nil || row.GuestRoot != nil {
		t.Errorf("the runtime keeps no unread bound, no kept folders and no machines: %+v", row)
	}
}
