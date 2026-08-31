// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import "testing"

// TestGroupCommandOrderCoversEveryCommand pins groupCommandOrder to the
// registered command set, in both directions: a command missing from its
// group's order silently sorts last in `cyfr --help` (how the map drifted
// out of date before), and a stale name is a rename or removal the map
// didn't follow.
func TestGroupCommandOrderCoversEveryCommand(t *testing.T) {
	listed := map[string]map[string]bool{}
	for group, names := range groupCommandOrder {
		listed[group] = map[string]bool{}
		for _, name := range names {
			if listed[group][name] {
				t.Errorf("groupCommandOrder[%q] lists %q twice", group, name)
			}
			listed[group][name] = true
		}
	}

	registered := map[string]map[string]bool{}
	for _, c := range rootCmd.Commands() {
		if c.GroupID == "" {
			continue
		}
		if registered[c.GroupID] == nil {
			registered[c.GroupID] = map[string]bool{}
		}
		registered[c.GroupID][c.Name()] = true

		if !listed[c.GroupID][c.Name()] {
			t.Errorf("command %q (group %q) is missing from groupCommandOrder — add it where it belongs in the group's workflow order",
				c.Name(), c.GroupID)
		}
	}

	for group, names := range groupCommandOrder {
		for _, name := range names {
			if !registered[group][name] {
				t.Errorf("groupCommandOrder[%q] lists %q, which is not a registered command in that group",
					group, name)
			}
		}
	}
}
