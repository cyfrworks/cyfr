// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package retire

import (
	"strconv"
	"testing"

	"github.com/cyfr/spawn/internal/residue"
)

func TestSpecValidation(t *testing.T) {
	valid := Spec{
		UID:     20007,
		GraceMs: 2000,
		Paths:   []string{"/var/lib/cyfr-bridge/homes/20007-0123456789abcdef0123456789abcdef", "/var/lib/cyfr-bridge/homes/left"},
	}
	if err := valid.Validate(); err != nil {
		t.Fatal(err)
	}
	noPaths := valid
	noPaths.Paths = nil
	if err := noPaths.Validate(); err != nil {
		t.Fatalf("a spec without paths was refused: %v", err)
	}

	var tooMany []string
	for i := 0; i <= residue.MaxPaths; i++ {
		tooMany = append(tooMany, "/homes/"+strconv.Itoa(i))
	}

	for name, s := range map[string]Spec{
		"root":                {UID: 0},
		"negative grace":      {UID: 20007, GraceMs: -1},
		"grace above maximum": {UID: 20007, GraceMs: 60_001},
		"relative path":       {UID: 20007, Paths: []string{"homes/x"}},
		"unclean path":        {UID: 20007, Paths: []string{"/homes/../etc"}},
		"the root":            {UID: 20007, Paths: []string{"/"}},
		"too many paths":      {UID: 20007, Paths: tooMany},
	} {
		if err := s.Validate(); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}
