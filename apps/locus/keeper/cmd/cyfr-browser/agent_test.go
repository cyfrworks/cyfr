// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

import (
	"encoding/json"
	"reflect"
	"testing"
)

// What the shell says of itself, as Debian's headless shell 156 answers a
// page of the reserved origin, becomes the same with its HeadlessChrome
// entries taken out: Chrome in place of HeadlessChrome in the User-Agent,
// and the brand and full-version lists otherwise as they were, in their
// order; nothing else is added, removed or changed.
func TestAgentTakesOutHeadlessChromeAlone(t *testing.T) {
	var own hints
	if err := json.Unmarshal([]byte(`{"architecture":"x86","bitness":"64",
		"brands":[{"brand":"Not:A-Brand","version":"8"},{"brand":"Chromium","version":"156"},{"brand":"HeadlessChrome","version":"156"}],
		"formFactors":["Desktop"],
		"fullVersionList":[{"brand":"Not:A-Brand","version":"8.0.0.0"},{"brand":"Chromium","version":"156.0.8078.79"},{"brand":"HeadlessChrome","version":"156.0.8078.79"}],
		"mobile":false,"model":"","platform":"Linux","platformVersion":"","uaFullVersion":"156.0.8078.79","wow64":false}`), &own); err != nil {
		t.Fatal(err)
	}
	got, err := agentOf("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) HeadlessChrome/156.0.8078.79 Safari/537.36", own)
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]any{
		"userAgent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/156.0.8078.79 Safari/537.36",
		"userAgentMetadata": map[string]any{
			"brands":          []brand{{"Not:A-Brand", "8"}, {"Chromium", "156"}},
			"fullVersionList": []brand{{"Not:A-Brand", "8.0.0.0"}, {"Chromium", "156.0.8078.79"}},
			"fullVersion":     "156.0.8078.79",
			"platform":        "Linux",
			"platformVersion": "",
			"architecture":    "x86",
			"bitness":         "64",
			"model":           "",
			"mobile":          false,
			"wow64":           false,
			"formFactors":     []string{"Desktop"},
		},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("agent\n got %#v\nwant %#v", got, want)
	}
	if _, err := agentOf("Mozilla/5.0", hints{}); err == nil {
		t.Fatal("hints naming no brand made an agent")
	}
}
