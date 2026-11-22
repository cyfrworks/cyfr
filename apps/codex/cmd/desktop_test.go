// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bufio"
	"bytes"
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

	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
)

// The app's cyfr binds the shell's listener before it says ready with the
// chooser's address and its run token, holds it alone, and ends when main
// says shutdown, locking and saying no lock of it.
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
	connecting := connectHeld(t, token)
	if _, err := io.WriteString(inW, `{"version":1,"type":"shutdown"}`+"\n"); err != nil {
		t.Fatal(err)
	}
	select {
	case said := <-connecting:
		if !strings.Contains(said, "CYFR locked. Connect again.") {
			t.Fatalf("shutdown did not lock: the Connect under way answered %s", said)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("shutdown left the Connect under way")
	}
	if lines.Scan() {
		t.Fatalf("an end of cyfr said something, which main would take for a lock: %s", lines.Text())
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

// connectHeld posts the chooser's Connect to a CYFR that takes the
// connection and answers nothing, and returns what it answers, once that
// CYFR was reached.
func connectHeld(t *testing.T, token string) <-chan string {
	t.Helper()
	silent, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	reached, done := make(chan struct{}), make(chan struct{})
	t.Cleanup(func() {
		close(done)
		silent.Close()
	})
	go func() {
		c, err := silent.Accept()
		if err != nil {
			return
		}
		defer c.Close()
		close(reached)
		<-done
	}()
	body, err := json.Marshal(map[string]string{"token": token, "address": "https://" + silent.Addr().String()})
	if err != nil {
		t.Fatal(err)
	}
	answered := make(chan string, 1)
	go func() {
		req, err := http.NewRequest(http.MethodPost, "http://127.0.0.1:7340/bootstrap/connect", bytes.NewReader(body))
		if err != nil {
			answered <- err.Error()
			return
		}
		req.Header.Set("Origin", "http://127.0.0.1:7340")
		req.Header.Set("Content-Type", "application/json")
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			answered <- err.Error()
			return
		}
		defer resp.Body.Close()
		raw, _ := io.ReadAll(resp.Body)
		answered <- string(raw)
	}()
	select {
	case <-reached:
	case said := <-answered:
		t.Fatalf("Connect answered before it reached the CYFR: %s", said)
	case <-time.After(10 * time.Second):
		t.Fatal("Connect never reached the CYFR")
	}
	return answered
}

// What the packaged program's help prints says nothing of a sign-in road
// or of a proof, and the command the app starts takes no flag for one.
func TestDesktopServeHelpShowsNoRoad(t *testing.T) {
	var words bytes.Buffer
	for _, c := range []*cobra.Command{rootCmd, desktopServeCmd} {
		c.SetOut(&words)
		if err := c.Help(); err != nil {
			t.Fatal(err)
		}
		c.SetOut(nil)
	}
	help := strings.ToLower(words.String())
	if !strings.Contains(help, "serve the cyfr app's pages to its main process") {
		t.Fatalf("that is not the command's help:\n%s", help)
	}
	for _, word := range []string{"account-road", "passkey road", "proof"} {
		if strings.Contains(help, word) {
			t.Fatalf("the help prints %q:\n%s", word, help)
		}
	}
	desktopServeCmd.LocalNonPersistentFlags().VisitAll(func(f *pflag.Flag) {
		if f.Name != "help" {
			t.Errorf("desktop-serve takes --%s", f.Name)
		}
	})
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
