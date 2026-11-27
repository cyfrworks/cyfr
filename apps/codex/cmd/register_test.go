// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"strings"
	"testing"
)

// TestRegisterHint: the "No components found" hint follows a scan that
// found nothing, and never one that refused what it found.
func TestRegisterHint(t *testing.T) {
	const empty = `{"status":"scanned","total":0,"registered":0,"unchanged":0,"errors":0,"components":[]}`
	const refused = `{"status":"scanned","total":0,"registered":0,"unchanged":0,"errors":1,` +
		`"components":[{"name":"big-tool","version":"1.0.0","type":"reagent","status":"error",` +
		`"error":"The component is 2949088 bytes, and a component runs only up to 2949087 bytes; make it smaller to register it."}]}`

	out, err := runCLI(t, newCLIServer(t, "", empty), "register")
	if err != nil {
		t.Fatalf("register: %v", err)
	}
	if !strings.Contains(out, "No components found") {
		t.Errorf("an empty scan prints no hint:\n%s", out)
	}

	out, err = runCLI(t, newCLIServer(t, "", refused), "register")
	if err != nil {
		t.Fatalf("register: %v", err)
	}
	if !strings.Contains(out, "make it smaller to register it") {
		t.Errorf("the refusal is not printed:\n%s", out)
	}
	if strings.Contains(out, "No components found") {
		t.Errorf("a scan that refused a component says none was found:\n%s", out)
	}
}
