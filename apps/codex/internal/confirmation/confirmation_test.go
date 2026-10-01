// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package confirmation

import (
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// The shared vector binds this derivation to Prima.Confirmation.ref/1, which
// reads the same file: a glass, the CLI and the home must name one record by
// one ref.
func TestRef_ReproducesTheSharedVector(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "..", "tests", "fixtures", "confirmation.json"))
	if err != nil {
		t.Fatalf("read shared fixture: %v", err)
	}

	var fixture struct {
		Ref struct {
			ID       string `json:"id"`
			Protocol string `json:"protocol"`
			Ref      string `json:"ref"`
		} `json:"ref"`
	}
	if err := json.Unmarshal(raw, &fixture); err != nil {
		t.Fatalf("decode shared fixture: %v", err)
	}
	if fixture.Ref.ID == "" || fixture.Ref.Ref == "" {
		t.Fatalf("the fixture carries no ref vector: %+v", fixture.Ref)
	}

	if fixture.Ref.Protocol != RefProtocol {
		t.Errorf("protocol: fixture %q, Go %q", fixture.Ref.Protocol, RefProtocol)
	}
	if got := Ref(fixture.Ref.ID); got != fixture.Ref.Ref {
		t.Errorf("Ref(%q) = %q, the vector says %q", fixture.Ref.ID, got, fixture.Ref.Ref)
	}
}

// A ref is spelled as the home spells one, and carries nothing of its id.
func TestRef_IsSpelledAsARefAndHidesTheId(t *testing.T) {
	id := "cnf_" + strings.Repeat("A", 43)
	ref := Ref(id)

	if !regexp.MustCompile(`\Acnr_[A-Za-z0-9_-]{43}\z`).MatchString(ref) {
		t.Errorf("ref %q is not cnr_ and 43 base64url characters", ref)
	}
	if strings.Contains(ref, strings.TrimPrefix(id, "cnf_")) {
		t.Errorf("ref %q carries its id", ref)
	}
	if Ref(id) != ref {
		t.Error("the same id must give the same ref")
	}
	if Ref(id+"B") == ref {
		t.Error("another id must give another ref")
	}
}
