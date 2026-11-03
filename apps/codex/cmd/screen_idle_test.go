//go:build linux

// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
package cmd

import (
	"context"
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
	err := runScreenShell(ctx)
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
	if err := runScreenShell(ctx); err == nil || ctx.Err() != nil || !strings.Contains(err.Error(), "swayidle") {
		t.Fatalf("no swayidle: err=%v context=%v", err, ctx.Err())
	}
}

// TestScreenShellHelper runs the screen's shell as a process of its own
// for TestScreenShell_AKilledShellLeavesNoChildBehind.
func TestScreenShellHelper(t *testing.T) {
	if os.Getenv("CYFR_SCREEN_SHELL_HELPER") == "" {
		t.Skip("run by TestScreenShell_AKilledShellLeavesNoChildBehind")
	}
	_ = runScreenShell(context.Background())
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
