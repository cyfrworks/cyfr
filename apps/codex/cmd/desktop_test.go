// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// The app's cyfr binds the shell's listener before it says ready with the
// chooser's address and its run token, holds it alone, and ends when main
// says shutdown, locked.
func TestDesktopServeSaysReadyHoldsItsPortAndEndsOnShutdown(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	inR, inW := io.Pipe()
	outR, outW := io.Pipe()
	ended := make(chan error, 1)
	go func() { ended <- runDesktopServe(context.Background(), inR, outW); outW.Close() }()
	lines := bufio.NewScanner(outR)
	read := func() map[string]any {
		t.Helper()
		if !lines.Scan() {
			t.Fatalf("cyfr said nothing more (%v)", lines.Err())
		}
		var m map[string]any
		if err := json.Unmarshal(lines.Bytes(), &m); err != nil {
			t.Fatalf("not a message: %q", lines.Text())
		}
		return m
	}
	ready := read()
	url, _ := ready["url"].(string)
	token, ok := strings.CutPrefix(url, "http://127.0.0.1:7340/bootstrap/#token=")
	if ready["type"] != "ready" || ready["version"] != float64(1) || !ok || len(token) != 43 {
		t.Fatalf("ready was %v", ready)
	}
	resp, err := http.Get("http://127.0.0.1:7340/bootstrap/")
	if err != nil || resp.StatusCode != http.StatusOK {
		t.Fatalf("the chooser is not served (%v)", err)
	}
	resp.Body.Close()
	if err := runDesktopServe(context.Background(), strings.NewReader(""), io.Discard); err == nil ||
		!strings.Contains(err.Error(), "close the app using port 7340") {
		t.Fatalf("a second cyfr took the port: %v", err)
	}
	if info, err := os.Stat(filepath.Join(home, ".cyfr", "device")); err != nil || !info.IsDir() {
		t.Fatalf("the device folder is %v (%v)", info, err)
	}
	if _, err := io.WriteString(inW, `{"version":1,"type":"shutdown"}`+"\n"); err != nil {
		t.Fatal(err)
	}
	if m := read(); m["type"] != "locked" {
		t.Fatalf("shutdown did not lock: %v", m)
	}
	select {
	case err := <-ended:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("shutdown did not end cyfr")
	}
	if _, err := http.Get("http://127.0.0.1:7340/bootstrap/"); err == nil {
		t.Fatal("the port is still served after shutdown")
	}
}

// The device's screen shares its account's client record with the CYFR
// app: it writes the record only once it holds the shell's listener, so a
// screen that loses the address to another program changes nothing.
func TestTheScreenWritesTheSharedRecordOnlyHoldingItsListener(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	record := filepath.Join(home, ".cyfr", "device", "client.json")
	held, err := net.Listen("tcp4", "127.0.0.1:7340")
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := screenClaim("/home/ada/cyfr"); err == nil {
		t.Fatal("the screen went on without its listener")
	}
	if _, err := os.Stat(record); !os.IsNotExist(err) {
		t.Fatalf("a screen without its listener wrote the record (%v)", err)
	}
	held.Close()
	ln, _, err := screenClaim("/home/ada/cyfr")
	if err != nil {
		t.Fatal(err)
	}
	ln.Close()
	if raw, err := os.ReadFile(record); err != nil || !strings.Contains(string(raw), `"project": "/home/ada/cyfr"`) {
		t.Fatalf("the screen holding its listener did not select its CYFR: %s (%v)", raw, err)
	}
}
