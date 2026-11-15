// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import "testing"

// `cyfr athanor get` reads the server's own `provisioned`, so a
// provisioned athanor is never called unprovisioned, and shows each
// setting the athanor holds; one not provisioned says why and where to
// retry it. `cyfr athanor` alone and `cyfr athanor show` say the same.
func TestAthanorGet_ReadsProvisionedAndShowsTheSettings(t *testing.T) {
	const provisioned = `{"name":"Me","route":"me","status":"active","provisioned":true,"settings":{"aqua":{"answer_mode":"all"},"theme":"dark"}}`
	const pending = `{"name":"Me","route":"me","status":"active","provisioned":false,"settings":{},` +
		`"provisioning_failure":{"step":"seed","detail":"bundle missing","at":"2026-11-15T00:00:00Z"}}`
	for _, args := range [][]string{{"athanor", "get"}, {"athanor"}, {"athanor", "show"}} {
		out, err := runCLI(t, newCLIServer(t, "", provisioned), args...)
		if want := "Me (me) — active\n  settings:\n    aqua.answer_mode=all\n    theme=dark\n"; err != nil || out != want {
			t.Errorf("cyfr %v printed %q (error %v), want %q", args, out, err, want)
		}
	}
	out, err := runCLI(t, newCLIServer(t, "", pending), "athanor", "get")
	if want := "Me (me) — active\n  not provisioned yet: retry it from the AQUA panel in CYFR\n" +
		"  the last attempt failed at seed: bundle missing\n"; err != nil || out != want {
		t.Errorf("an unprovisioned athanor printed %q (error %v), want %q", out, err, want)
	}
}
