// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package locusroles

import (
	"encoding/json"
	"reflect"
	"testing"

	"github.com/cyfr/locus/keeper/internal/wire/wiretest"
)

// The runtime row of tests/fixtures/locus_roles.json, every row read
// strictly into Role: a member Role lacks, or one it has that a row lacks,
// fails.
func runtimeRow(t *testing.T) Role {
	t.Helper()
	var table struct {
		Roles []json.RawMessage `json:"roles"`
	}
	wiretest.Load(t, "locus_roles.json", &table)
	for _, raw := range table.Roles {
		var role Role
		wiretest.Value(t, raw, &role)
		if role.Name == "runtime" {
			return role
		}
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
