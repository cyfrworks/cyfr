//go:build linux

// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
package cmd

import (
	"context"
	"os"
	"path/filepath"
	"strings"
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
