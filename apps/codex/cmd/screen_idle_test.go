//go:build linux

// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
package cmd

import (
	"context"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestScreenShell_AnIdleWatcherThatExitsLocksAndEndsTheShell(t *testing.T) {
	screenProject(t)
	if err := os.MkdirAll(screenDir, 0700); err != nil {
		t.Fatal(err)
	}
	bin := t.TempDir()
	for name, script := range map[string]string{
		"pkill":                "exit 0",
		"wvkbd-mobintl":        "exec /bin/sleep 30",
		"swayidle":             "exit 42",
		"google-chrome-stable": "exec /bin/sleep 30",
	} {
		if err := os.WriteFile(filepath.Join(bin, name), []byte("#!/bin/sh\n"+script+"\n"), 0700); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("PATH", bin+":/usr/bin:/bin")
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	listen, _ := ownListener()
	err := runScreenShell(ctx, listen)
	if err == nil || ctx.Err() != nil || !strings.Contains(err.Error(), "idle lock (swayidle) stopped") {
		t.Fatalf("idle watcher exited 42, screen ran until outer cancellation: err=%v context=%v", err, ctx.Err())
	}
}

// A screen with no idle watcher to start never runs unlocked: the shell
// ends at once, saying why.
func TestScreenShell_NoIdleWatcherEndsTheShell(t *testing.T) {
	screenProject(t)
	if err := os.MkdirAll(screenDir, 0o700); err != nil {
		t.Fatal(err)
	}
	bin := t.TempDir()
	for name, script := range map[string]string{
		"pkill":                "exit 0",
		"wvkbd-mobintl":        "exec /bin/sleep 30",
		"google-chrome-stable": "exec /bin/sleep 30",
	} {
		if err := os.WriteFile(filepath.Join(bin, name), []byte("#!/bin/sh\n"+script+"\n"), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("PATH", bin)
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	listen, _ := ownListener()
	if err := runScreenShell(ctx, listen); err == nil || ctx.Err() != nil || !strings.Contains(err.Error(), "swayidle") {
		t.Fatalf("no swayidle: err=%v context=%v", err, ctx.Err())
	}
}

// TestScreenShellHelper runs the screen's shell as a process of its own
// for TestScreenShell_AKilledShellLeavesNoChildBehind.
func TestScreenShellHelper(t *testing.T) {
	if os.Getenv("CYFR_SCREEN_SHELL_HELPER") == "" {
		t.Skip("run by TestScreenShell_AKilledShellLeavesNoChildBehind")
	}
	listen, _ := ownListener()
	_ = runScreenShell(context.Background(), listen)
}

// A shell killed outright leaves no keyboard, idle watch or Chrome behind:
// each ends with it.
func TestScreenShell_AKilledShellLeavesNoChildBehind(t *testing.T) {
	screenProject(t)
	if err := os.MkdirAll(screenDir, 0o700); err != nil {
		t.Fatal(err)
	}
	bin, pids := t.TempDir(), t.TempDir()
	children := []string{"wvkbd-mobintl", "swayidle", "google-chrome-stable"}
	for _, name := range children {
		script := "echo $$ >" + filepath.Join(pids, name) + "\nexec /bin/sleep 60\n"
		if err := os.WriteFile(filepath.Join(bin, name), []byte("#!/bin/sh\n"+script), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(bin, "pkill"), []byte("#!/bin/sh\nexit 1\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	shell := exec.Command(os.Args[0], "-test.run=^TestScreenShellHelper$")
	shell.Env = append(os.Environ(), "CYFR_SCREEN_SHELL_HELPER=1", "PATH="+bin+":/usr/bin:/bin")
	if err := shell.Start(); err != nil {
		t.Fatal(err)
	}
	var running []int
	for deadline := time.Now().Add(10 * time.Second); len(running) < len(children); {
		if time.Now().After(deadline) {
			_ = shell.Process.Kill()
			t.Fatalf("the shell started %d of its children", len(running))
		}
		running = running[:0]
		for _, name := range children {
			if raw, err := os.ReadFile(filepath.Join(pids, name)); err == nil {
				if pid, err := strconv.Atoi(strings.TrimSpace(string(raw))); err == nil {
					running = append(running, pid)
				}
			}
		}
		time.Sleep(20 * time.Millisecond)
	}
	_ = shell.Process.Signal(syscall.SIGKILL)
	_ = shell.Wait()
	deadline := time.Now().Add(3 * time.Second)
	for _, pid := range running {
		for syscall.Kill(pid, 0) == nil {
			if time.Now().After(deadline) {
				_ = syscall.Kill(pid, syscall.SIGKILL)
				t.Fatalf("child %d outlived the killed shell", pid)
			}
			time.Sleep(20 * time.Millisecond)
		}
	}
}

// A folder that names another CYFR than the one the screen opened ends
// the screen's shell, which its launcher starts again on that reading,
// and Chrome is given localhost as 127.0.0.1 alone.
func TestScreenShell_AChangedFolderEndsTheShellForANewReading(t *testing.T) {
	screenProject(t)
	if err := os.MkdirAll(screenDir, 0o700); err != nil {
		t.Fatal(err)
	}
	bin := t.TempDir()
	chromed := filepath.Join(bin, "chrome.args")
	for name, script := range map[string]string{
		"pkill":                "exit 0",
		"wvkbd-mobintl":        "exec /bin/sleep 30",
		"swayidle":             "exec /bin/sleep 30",
		"google-chrome-stable": `echo "$@" >` + chromed + `; exec /bin/sleep 30`,
	} {
		if err := os.WriteFile(filepath.Join(bin, name), []byte("#!/bin/sh\n"+script+"\n"), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("PATH", bin+":/usr/bin:/bin")
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	listen, address := ownListener()
	ended := make(chan error, 1)
	go func() { ended <- runScreenShell(ctx, listen) }()
	for {
		if raw, err := os.ReadFile(chromed); err == nil && strings.HasSuffix(string(raw), "\n") {
			if !strings.Contains(string(raw), "--host-resolver-rules=MAP localhost 127.0.0.1") {
				t.Errorf("Chrome was started with %s", raw)
			}
			break
		}
		select {
		case err := <-ended:
			t.Fatalf("the screen ended first: %v", err)
		case <-time.After(20 * time.Millisecond):
		}
	}
	if err := os.WriteFile(".env", []byte("CYFR_ACCESS=local\nCYFR_PORT=4322\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	req, err := http.NewRequest(http.MethodGet, "http://"+address()+"/", nil)
	if err != nil {
		t.Fatal(err)
	}
	req.Host = "127.0.0.1:7340"
	if resp, err := http.DefaultClient.Do(req); err == nil {
		resp.Body.Close()
	}
	select {
	case err := <-ended:
		if err == nil || ctx.Err() != nil || !strings.Contains(err.Error(), "starts again") {
			t.Fatalf("the screen ended with %v", err)
		}
	case <-time.After(20 * time.Second):
		t.Fatal("the screen kept the CYFR it read before")
	}
}
