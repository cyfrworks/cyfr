// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package ref

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// The shared fixture binds this parser's verdicts to Sanctum.ComponentRef's
// (its Elixir twin reads the same file from cross_language_drift_test.exs).
// The drift test proves both sources spell the same regexes; this proves
// they reach the same verdicts. Every case carries a full
// type:namespace.name:version ref on purpose — the sides differ
// deliberately on MISSING segments (this CLI accepts typeless/bare refs and
// infers elsewhere; the server refuses them), and that difference belongs
// to each side's own tests.
type fixtureCase struct {
	Ref       string `json:"ref"`
	Valid     bool   `json:"valid"`
	Type      string `json:"type"`
	Namespace string `json:"namespace"`
	Name      string `json:"name"`
	Version   string `json:"version"`
	Why       string `json:"why"`
}

func TestSharedFixtureVerdicts(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "..", "tests", "fixtures", "component_refs.json"))
	if err != nil {
		t.Fatalf("read shared fixture: %v", err)
	}

	var fixture struct {
		Cases []fixtureCase `json:"cases"`
	}
	if err := json.Unmarshal(raw, &fixture); err != nil {
		t.Fatalf("decode shared fixture: %v", err)
	}
	if len(fixture.Cases) == 0 {
		t.Fatal("shared fixture has no cases")
	}

	for _, c := range fixture.Cases {
		p := ParseRef(c.Ref)
		err := Validate(p)

		if c.Valid {
			if err != nil {
				t.Errorf("%s: refused (%v) but the fixture says valid", c.Ref, err)
				continue
			}
			if got := ExpandType(p.Type); got != c.Type {
				t.Errorf("%s: type %q, fixture says %q", c.Ref, got, c.Type)
			}
			if p.Namespace != c.Namespace {
				t.Errorf("%s: namespace %q, fixture says %q", c.Ref, p.Namespace, c.Namespace)
			}
			if p.Name != c.Name {
				t.Errorf("%s: name %q, fixture says %q", c.Ref, p.Name, c.Name)
			}
			if p.Version != c.Version {
				t.Errorf("%s: version %q, fixture says %q", c.Ref, p.Version, c.Version)
			}
		} else if err == nil {
			t.Errorf("%s: validated but the fixture says invalid (%s)", c.Ref, c.Why)
		}
	}
}
