// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package stage

import (
	"os"
	"strings"
	"testing"
)

// A namespace of the stage's own maps exactly its id to itself; the
// initial namespace, a container's remapped one and a map with a second
// line are not one.
func TestIdentityOnlyIsTheSpawnsIDAlone(t *testing.T) {
	for idMap, want := range map[string]bool{
		"     30101      30101          1\n": true,
		"30101 30101 1":                      true,
		"         0          0 4294967295\n": false,
		"         0     100000      65536\n": false,
		"30101 30101 2\n":                    false,
		"30102 30102 1\n":                    false,
		"30101 30102 1\n":                    false,
		"30101 30101 1\n0 0 1\n":             false,
		"":                                   false,
	} {
		if got := identityOnly([]byte(idMap), 30101); got != want {
			t.Errorf("identityOnly(%q) = %t, want %t", idMap, got, want)
		}
	}
}

// Outside a namespace of its own the stage says so, whatever uid it is
// asked about: the test runs in the namespace it was started in.
func TestOwnNamespaceIsNotTheTestsOwn(t *testing.T) {
	uidMap, err := os.ReadFile("/proc/self/uid_map")
	if err != nil {
		t.Skip(err)
	}
	if strings.Count(strings.TrimSpace(string(uidMap)), "\n") != 0 || strings.HasSuffix(strings.TrimSpace(string(uidMap)), " 1") {
		t.Skipf("the test runs in a user namespace mapping %q", uidMap)
	}
	isolated, err := ownNamespace(30101, 30101)
	if err != nil || isolated {
		t.Fatalf("ownNamespace = %t, %v", isolated, err)
	}
}
