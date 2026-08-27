// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import "testing"

func TestValidateContextURL(t *testing.T) {
	valid := []string{
		"http://127.0.0.1:4000",
		"http://localhost:4000",
		"https://cyfr.example.com",
		"https://cyfr.corp.internal:4000",
	}
	for _, u := range valid {
		if err := validateContextURL(u); err != nil {
			t.Errorf("expected %q to be valid, got error: %v", u, err)
		}
	}

	invalid := []string{
		"ftp://example.com",
		"file:///etc/passwd",
		"notaurl",
		"https://",
		"://nohost",
	}
	for _, u := range invalid {
		if err := validateContextURL(u); err == nil {
			t.Errorf("expected %q to be rejected", u)
		}
	}
}

func TestIsLoopbackHost(t *testing.T) {
	for _, h := range []string{"localhost", "127.0.0.1", "127.0.0.53", "::1"} {
		if !isLoopbackHost(h) {
			t.Errorf("expected %q to be loopback", h)
		}
	}
	for _, h := range []string{"cyfr.example.com", "10.0.0.1", "example.org"} {
		if isLoopbackHost(h) {
			t.Errorf("expected %q to be non-loopback", h)
		}
	}
}
