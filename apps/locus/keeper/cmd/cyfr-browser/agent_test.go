// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

import (
	"reflect"
	"testing"
)

// The shell's own version and User-Agent become the Chromium it is: Chrome
// in place of HeadlessChrome and Chromium its one brand, at its version
// and on this machine; an answer naming no version changes nothing.
func TestAgentNamesTheChromiumItIs(t *testing.T) {
	got := agentOf(version{
		Product:   "HeadlessChrome/156.0.8078.79",
		UserAgent: "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) HeadlessChrome/156.0.8078.79 Safari/537.36",
	}, "arm64")
	want := map[string]any{
		"userAgent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/156.0.8078.79 Safari/537.36",
		"userAgentMetadata": map[string]any{
			"brands":          []map[string]string{{"brand": "Chromium", "version": "156"}},
			"fullVersionList": []map[string]string{{"brand": "Chromium", "version": "156.0.8078.79"}},
			"fullVersion":     "156.0.8078.79",
			"platform":        "Linux",
			"platformVersion": "",
			"architecture":    "arm",
			"bitness":         "64",
			"model":           "",
			"mobile":          false,
			"wow64":           false,
		},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("agent\n got %#v\nwant %#v", got, want)
	}
	if got := agentOf(version{Product: "HeadlessChrome", UserAgent: "x"}, "amd64"); got != nil {
		t.Fatalf("an answer naming no version: %#v", got)
	}
}
