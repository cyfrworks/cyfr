// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"strings"
	"testing"
)

// ---------------------------------------------------------------------------
// The credentials a grant binds
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// A re-grant
// ---------------------------------------------------------------------------

// A listed profile's head reads as what the home answered of it: its
// revision when it was read, none when the profile has no head, and a
// damaged or unreadable head as such, never as none.
func TestProfileList_SaysWhatStandsInPlaceOfAHead(t *testing.T) {
	srv := newCLIServer(t, "", `{"profiles":[`+
		`{"id":"prof_present","kind":"owner","status":"active","head_state":"present","head_revision":3},`+
		`{"id":"prof_missing","kind":"owner","status":"active","head_state":"missing","head_revision":null},`+
		`{"id":"prof_damaged","kind":"owner","status":"active","head_state":"damaged","head_revision":null},`+
		`{"id":"prof_unavailable","kind":"owner","status":"active","head_state":"unavailable","head_revision":null},`+
		`{"id":"prof_invalid","kind":"owner","status":"active","head_state":"invalid","head_revision":2},`+
		`{"id":"prof_unread_revision","kind":"owner","status":"active","head_state":"present","head_revision":null}]}`)

	out, err := runCLI(t, srv, "profile", "list", "reagent:local.listed")
	if err != nil {
		t.Fatalf("cyfr profile list failed: %v\n%s", err, out)
	}

	want := map[string]string{
		"prof_present":         "consent rev 3",
		"prof_missing":         "consent rev none",
		"prof_damaged":         "consent damaged",
		"prof_unavailable":     "consent unavailable — try again",
		"prof_invalid":         "consent damaged",
		"prof_unread_revision": "consent damaged",
	}

	lines := strings.Split(strings.TrimSpace(out), "\n")
	if len(lines) != len(want) {
		t.Fatalf("listed %d profiles, want %d:\n%s", len(lines), len(want), out)
	}
	for _, line := range lines {
		id := strings.Fields(line)[0]
		head, ok := want[id]
		if !ok {
			t.Errorf("listed a profile the home did not answer: %q", line)
			continue
		}
		if !strings.HasSuffix(line, " "+head) {
			t.Errorf("%s reads %q, want its head as %q", id, line, head)
		}
	}
}
