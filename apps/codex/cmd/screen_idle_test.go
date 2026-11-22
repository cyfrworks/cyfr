//go:build linux

// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
package cmd

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/cyfr/codex/internal/idle/idletest"
)

// screenCompositor is the compositor of this test's screen, which its
// subprocesses find as the screen's shell does.
func screenCompositor(t *testing.T, o idletest.Options) *idletest.Compositor {
	t.Helper()
	c := idletest.Start(t, o)
	t.Setenv("WAYLAND_DISPLAY", c.Socket)
	return c
}

// screenPrograms puts stand-ins of the screen's programs first on PATH.
func screenPrograms(t *testing.T, scripts map[string]string) {
	t.Helper()
	bin := t.TempDir()
	for name, script := range scripts {
		if err := os.WriteFile(filepath.Join(bin, name), []byte("#!/bin/sh\n"+script+"\n"), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("PATH", bin+":/usr/bin:/bin")
}

// quietScreen is the screen's programs, each running and doing nothing.
func quietScreen() map[string]string {
	return map[string]string{
		"pkill":                "exit 0",
		"wvkbd-mobintl":        "exec /bin/sleep 30", // sleep-ok: a stand-in child that runs until the shell ends it
		"swayidle":             "exec /bin/sleep 30", // sleep-ok: a stand-in child that runs until the shell ends it
		"google-chrome-stable": "exec /bin/sleep 30", // sleep-ok: a stand-in child that runs until the shell ends it
	}
}

func lockedWith(t *testing.T, locks <-chan string, want string) {
	t.Helper()
	select {
	case why := <-locks:
		if why != want {
			t.Fatalf("locked saying %q, want %q", why, want)
		}
	case <-time.After(10 * time.Second):
		t.Fatalf("the screen did not lock (%q)", want)
	}
}

// A page that holds the compositor awake, as one playing video with sound
// does, does not hold the screen's lock off.
func TestScreenWatch_LocksWhateverHoldsTheScreenAwake(t *testing.T) {
	screenCompositor(t, idletest.Options{Inhibited: true})
	screenPrograms(t, quietScreen())
	locks := make(chan string, 8)
	_, stop, err := watchScreen(t.Context(), 20*time.Millisecond, func(why string) { locks <- why })
	if err != nil {
		t.Fatal(err)
	}
	defer stop()
	lockedWith(t, locks, idleLocked)
}

// A suspend locks: swayidle runs what it is given before a sleep.
func TestScreenWatch_ASuspendLocks(t *testing.T) {
	screenCompositor(t, idletest.Options{})
	programs := quietScreen()
	// swayidle -w before-sleep COMMAND, as the computer goes to sleep.
	// sleep-ok: the stand-in runs on until the watch is stopped.
	programs["swayidle"] = `[ "$1" = -w ] && [ "$2" = before-sleep ] && [ "$#" = 3 ] || exit 64
sh -c "$3"
exec /bin/sleep 30`
	screenPrograms(t, programs)
	locks := make(chan string, 8)
	_, stop, err := watchScreen(t.Context(), time.Hour, func(why string) { locks <- why })
	if err != nil {
		t.Fatal(err)
	}
	defer stop()
	lockedWith(t, locks, suspendLocked)
}

// screenWatchAfter is set where tests/desktop-proof/screen/idle.sh runs
// TestScreenWatchHelper under a real compositor.
const screenWatchAfter = "CYFR_SCREEN_WATCH_AFTER"

// TestScreenWatchHelper is the screen's watches as a process of their own,
// counting a time short enough to wait for, for that proof to read.
func TestScreenWatchHelper(t *testing.T) {
	if os.Getenv(screenWatchAfter) == "" {
		t.Skip("run by tests/desktop-proof/screen/idle.sh")
	}
	after, err := time.ParseDuration(os.Getenv(screenWatchAfter))
	if err != nil {
		t.Fatal(err)
	}
	ended, stop, err := watchScreen(t.Context(), after, func(why string) { fmt.Println("locked: " + why) })
	if err != nil {
		t.Fatal(err)
	}
	defer stop()
	fmt.Println("watching")
	t.Fatal(<-ended)
}

// The screen's shell counts its five minutes from input alone, and ends
// when it can count them no longer, for the launcher to start it locked.
func TestScreenShell_CountsFiveMinutesOfInputAloneAndEndsWithoutThem(t *testing.T) {
	screenProject(t)
	compositor := screenCompositor(t, idletest.Options{})
	screenPrograms(t, quietScreen())
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	ended := make(chan error, 1)
	go func() { ended <- runScreenShell(ctx) }()
	select {
	case asked := <-compositor.Asked:
		if !asked.InputOnly || asked.After != 5*time.Minute {
			t.Fatalf("the screen asked for %+v, want five minutes of input alone", asked)
		}
	case err := <-ended:
		t.Fatalf("the shell ended before it asked: %v", err)
	case <-ctx.Done():
		t.Fatal("the screen never asked the compositor to count input alone")
	}
	compositor.Stop()
	if err := <-ended; err == nil || ctx.Err() != nil || !strings.Contains(err.Error(), "idle lock stopped") {
		t.Fatalf("the compositor went, and the screen ran on: err=%v context=%v", err, ctx.Err())
	}
}

// A compositor that cannot count input alone never runs an unlocked screen.
func TestScreenShell_NoInputIdleEndsTheShell(t *testing.T) {
	screenProject(t)
	screenCompositor(t, idletest.Options{Version: 1})
	screenPrograms(t, quietScreen())
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if err := runScreenShell(ctx); err == nil || ctx.Err() != nil || !strings.Contains(err.Error(), "idle lock did not start") {
		t.Fatalf("no input-only idle: err=%v context=%v", err, ctx.Err())
	}
}

func TestScreenShell_ASuspendWatcherThatExitsLocksAndEndsTheShell(t *testing.T) {
	screenProject(t)
	screenCompositor(t, idletest.Options{})
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
	if err == nil || ctx.Err() != nil || !strings.Contains(err.Error(), "suspend lock (swayidle) stopped") {
		t.Fatalf("suspend watcher exited 42, screen ran until outer cancellation: err=%v context=%v", err, ctx.Err())
	}
}

// A screen with no suspend watcher to start never runs unlocked: the shell
// ends at once, saying why.
func TestScreenShell_NoSuspendWatcherEndsTheShell(t *testing.T) {
	screenProject(t)
	screenCompositor(t, idletest.Options{})
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

// A shell killed outright leaves no keyboard, suspend watch or Chrome
// behind: each ends with it.
func TestScreenShell_AKilledShellLeavesNoChildBehind(t *testing.T) {
	screenProject(t)
	screenCompositor(t, idletest.Options{})
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
