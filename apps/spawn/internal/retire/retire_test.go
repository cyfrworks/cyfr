// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package retire

import "testing"

func TestSpecValidation(t *testing.T) {
	valid := Spec{
		UID:      20007,
		HomeRoot: "/var/lib/cyfr-bridge/homes",
		Home:     "/var/lib/cyfr-bridge/homes/20007-0123456789abcdef0123456789abcdef",
		GraceMs:  2000,
	}
	if err := valid.Validate(); err != nil {
		t.Fatal(err)
	}
	noHome := valid
	noHome.Home = ""
	if err := noHome.Validate(); err != nil {
		t.Fatalf("a spec without a home was refused: %v", err)
	}

	for name, mutate := range map[string]func(*Spec){
		"root":                  func(s *Spec) { s.UID = 0 },
		"negative grace":        func(s *Spec) { s.GraceMs = -1 },
		"grace above maximum":   func(s *Spec) { s.GraceMs = 60_001 },
		"home of another uid":   func(s *Spec) { s.UID = 20008 },
		"home outside the root": func(s *Spec) { s.Home = "/etc/20007-0123456789abcdef0123456789abcdef" },
	} {
		s := valid
		mutate(&s)
		if err := s.Validate(); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}
