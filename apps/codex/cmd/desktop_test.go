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
	"sync"
	"testing"
	"time"

	"github.com/spf13/cobra"
	"github.com/spf13/pflag"

	"github.com/cyfr/codex/internal/desktop"
	"github.com/cyfr/codex/internal/shell"
)

// ownListener is what production gives as shell.ListenLoopback, on a port
// of the test's own: its first listener takes a free one and every other
// asks for that same one, which address answers. No test binds shell.Listen.
func ownListener() (listen func() (net.Listener, error), address func() string) {
	var mu sync.Mutex
	taken := "127.0.0.1:0"
	listen = func() (net.Listener, error) {
		mu.Lock()
		defer mu.Unlock()
		ln, err := shell.ListenAt(taken)
		if err == nil {
			taken = ln.Addr().String()
		}
		return ln, err
	}
	address = func() string {
		mu.Lock()
		defer mu.Unlock()
		return taken
	}
	return listen, address
}

// A message to main that cannot be written ends desktop-serve: with main's
// end of the pipe closed, the write of ready fails, the serve returns,
// saying why, and nothing is served on its port afterwards.
func TestDesktopServeEndsWhenAWriteToMainFails(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	inR, inW := io.Pipe()
	t.Cleanup(func() { inW.Close() })
	outR, outW := io.Pipe()
	outR.Close()
	listen, address := ownListener()
	ended := make(chan error, 1)
	go func() { ended <- runDesktopServe(context.Background(), listen, "", inR, outW) }()
	select {
	case err := <-ended:
		if err == nil || !strings.Contains(err.Error(), "could not be written") {
			t.Fatalf("desktop-serve ended with %v", err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("desktop-serve went on serving after a write to main failed")
	}
	if c, err := net.DialTimeout("tcp", address(), time.Second); err == nil {
		c.Close()
		t.Fatal("its port is still served")
	}
}

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
	listen, address := ownListener()
	go func() { ended <- runDesktopServe(context.Background(), listen, "", inR, outW); outW.Close() }()
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
	if ready["type"] != "ready" || ready["version"] != float64(desktop.Version) || !ok || len(token) != 43 {
		t.Fatalf("ready was %v", ready)
	}
	chooser := func() (*http.Response, error) {
		req, err := http.NewRequest(http.MethodGet, "http://"+address()+"/bootstrap/", nil)
		if err != nil {
			return nil, err
		}
		req.Host = shell.Listen
		return http.DefaultClient.Do(req)
	}
	resp, err := chooser()
	if err != nil || resp.StatusCode != http.StatusOK {
		t.Fatalf("the chooser is not served (%v)", err)
	}
	resp.Body.Close()
	if err := runDesktopServe(context.Background(), listen, "", strings.NewReader(""), io.Discard); err == nil ||
		!strings.Contains(err.Error(), "close the app using port 7340") {
		t.Fatalf("a second cyfr took the port: %v", err)
	}
	if info, err := os.Stat(filepath.Join(home, ".cyfr", "device")); err != nil || !info.IsDir() {
		t.Fatalf("the device folder is %v (%v)", info, err)
	}
	connecting := connectHeld(t, address(), token)
	if _, err := io.WriteString(inW, `{"version":2,"type":"shutdown"}`+"\n"); err != nil {
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
	if resp, err := chooser(); err == nil {
		resp.Body.Close()
		t.Fatal("the port is still served after shutdown")
	}
}

// connectHeld posts the chooser's Connect at listener to a CYFR that takes
// the connection and answers nothing, and returns what it answers, once
// that CYFR was reached.
func connectHeld(t *testing.T, listener, token string) <-chan string {
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
	body, err := json.Marshal(map[string]string{"address": "https://" + silent.Addr().String()})
	if err != nil {
		t.Fatal(err)
	}
	answered := make(chan string, 1)
	go func() {
		req, err := http.NewRequest(http.MethodPost, "http://"+listener+"/bootstrap/connect", bytes.NewReader(body))
		if err != nil {
			answered <- err.Error()
			return
		}
		req.Host = shell.Listen
		req.Header.Set("Origin", shell.Origin)
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set(desktop.RunHeader, token)
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

// desktop-serve's setup suggests the folder cyfr setup opened the app in,
// and ~/cyfr when the app was opened without one; a folder that is not an
// absolute path is refused before anything is served.
func TestDesktopServeSuggestsTheFolderItIsGiven(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	given := filepath.Join(t.TempDir(), "setup-here")
	for folder, want := range map[string]string{given: given, "": filepath.Join(home, "cyfr")} {
		if got := newDesktopService(t.Context(), t.TempDir(), folder, func(desktop.Message) {}).Folder; got != want {
			t.Errorf("given %q, the setup suggests %q, want %q", folder, got, want)
		}
	}
	err := desktopServeCmd.RunE(desktopServeCmd, []string{"setup-here"})
	if err == nil || err.Error() != `the folder to suggest is "setup-here", not an absolute path` {
		t.Errorf("desktop-serve with a relative folder answered %v", err)
	}
}
