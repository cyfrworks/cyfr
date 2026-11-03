// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"net"
	"testing"
)

// TestHomeHere: a home on loopback, or at one of this machine's own
// addresses, is on this machine; an address of no interface here is not.
func TestHomeHere(t *testing.T) {
	t.Chdir(t.TempDir())
	cases := map[string]bool{
		"http://127.0.0.1:4000":  true,
		"http://localhost:4000":  true,
		"http://LOCALHOST:4000/": true,
		"http://[::1]:4000":      true,
		"https://192.0.2.10":     false, // TEST-NET-1, assigned to no interface
		"https://[2001:db8::10]": false,
		"not an address":         false,
	}
	own, _ := net.InterfaceAddrs()
	for _, a := range own {
		if n, ok := a.(*net.IPNet); ok && !n.IP.IsLoopback() && n.IP.To4() != nil {
			cases["https://"+n.IP.String()] = true
			break
		}
	}
	for address, want := range cases {
		if got := homeHere(address); got != want {
			t.Errorf("homeHere(%q) = %v, want %v", address, got, want)
		}
	}
}
