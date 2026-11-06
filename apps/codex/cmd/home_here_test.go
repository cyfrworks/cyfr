// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"net"
	"os"
	"path/filepath"
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

// The box's own screen counts its home as this machine whatever the
// address it is reached at.
func TestScreenShell_TheHomeIsThisMachine(t *testing.T) {
	if c := screenShellConfig(t.TempDir(), "https://box.tail0000.ts.net", nil, "box", func() {}); !c.HomeHere {
		t.Fatalf("the screen's shell: HomeHere %v", c.HomeHere)
	}
}

// The stack in the working directory, reached through a tailnet node in
// a container, names no address of this machine's interfaces: its .env
// says the home is here.
func TestHomeHere_TheStackHereServesIt(t *testing.T) {
	dir := t.TempDir()
	t.Chdir(dir)
	env := "CYFR_ACCESS=tailnet\nCYFR_HOST=cyfr.tail1234.ts.net\nCYFR_PUBLIC_URL=https://cyfr.tail1234.ts.net\nCYFR_TAILNET_NODE_ID=nTESTNODE1CNTRL\nCYFR_PORT=4000\n"
	if err := os.WriteFile(filepath.Join(dir, ".env"), []byte(env), 0o600); err != nil {
		t.Fatal(err)
	}
	if !stackServes("https://cyfr.tail1234.ts.net") || !homeHere("https://cyfr.tail1234.ts.net/") {
		t.Fatal("the stack here does not serve its own address")
	}
	if stackServes("https://other.tail1234.ts.net") {
		t.Fatal("the stack here serves another home's address")
	}
}
