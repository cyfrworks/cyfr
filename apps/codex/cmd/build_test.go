// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import "testing"

// The note names a command that exists, with the reference it was given.
func TestRegistrationNote_NamesARealCommand(t *testing.T) {
	ref := "catalyst:local.my-api:0.1.0"

	got := registrationNote("pending", ref)
	want := "Registration: pending (the server registers the artifact in the background; check 'cyfr inspect catalyst:local.my-api:0.1.0')"
	if got != want {
		t.Fatalf("registrationNote = %q, want %q", got, want)
	}

	found, _, err := rootCmd.Find([]string{"inspect", ref})
	if err != nil || found.Name() != "inspect" {
		t.Fatalf("the note names 'cyfr inspect', which is not a command: %v", err)
	}

	for _, done := range []string{"", "done"} {
		if note := registrationNote(done, ref); note != "" {
			t.Fatalf("registrationNote(%q) = %q, want none", done, note)
		}
	}
}
