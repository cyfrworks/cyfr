// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package apparmor

import (
	"bytes"
	"os"
	"strings"
	"testing"
)

// The name file holds the name the rule gives this profile, which the
// image, the dev loop and CI read: a profile changed without it fails here.
func TestTheNameFileIsTheProfiles(t *testing.T) {
	held, err := os.ReadFile("name")
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.TrimSpace(string(held)); got != ProfileName {
		t.Fatalf("the file name holds %q; the profile's name is %q: write %s there", got, ProfileName, ProfileName)
	}
}

// Any change to the profile's text is another name, and the profile root
// loads carries its name in every place the placeholder held.
func TestTheNameCarriesTheContent(t *testing.T) {
	if Name(append(bytes.Clone(template), ' ')) == ProfileName {
		t.Fatal("a changed profile keeps its name")
	}
	if bytes.Contains(Profile, []byte(Placeholder)) || bytes.Count(Profile, []byte(ProfileName)) != bytes.Count(template, []byte(Placeholder)) {
		t.Fatalf("the profile root loads does not carry %s in every place of its placeholder", ProfileName)
	}
	if !strings.HasPrefix(ProfileName, "cyfr-locus-") || len(ProfileName) != len(Placeholder) {
		t.Fatalf("the name %q is not cyfr-locus- and 12 hex digits", ProfileName)
	}
}
