// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package home

import (
	"testing"
)

func TestParseKept(t *testing.T) {
	k, err := ParseKept("/var/lib/locus/kept:40001-49999")
	if err != nil || k != (Kept{Root: "/var/lib/locus/kept", First: 40001, Last: 49999}) {
		t.Fatalf("parsed %+v %v", k, err)
	}
	if k.String() != "/var/lib/locus/kept:40001-49999" || !k.Contains(40001) || !k.Contains(49999) || k.Contains(50000) {
		t.Fatalf("kept %+v", k)
	}
	for _, bad := range []string{"", "/k", "k:1-2", "/:1-2", "/k/:1-2", "/k:2-1", "/k:0-2", "/k:1-x", "/k:1-70000"} {
		if _, err := ParseKept(bad); err == nil {
			t.Errorf("%q accepted", bad)
		}
	}
}

func TestKeptValidate(t *testing.T) {
	k := Kept{Root: "/k", First: 10, Last: 20}
	if err := k.Validate("/k/vlt_01a-b_c", 15); err != nil {
		t.Fatal(err)
	}
	for path, uid := range map[string]int{
		"/k/vlt_a":     21,
		"/k/a/b":       15,
		"/other/vlt_a": 15,
		"/k/../k/a":    15,
		"/k/.hidden":   15,
		"/k":           15,
	} {
		if err := k.Validate(path, uid); err == nil {
			t.Errorf("%s as %d accepted", path, uid)
		}
	}
}
