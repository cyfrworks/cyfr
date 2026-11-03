// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build !windows

package cmd

import (
	"bytes"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/cyfr/codex/internal/config"
	"github.com/cyfr/codex/internal/shell"
)

func shellScript(t *testing.T, body string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "shell")
	if err := os.WriteFile(path, []byte("#!/bin/sh\n"+body+"\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	return path
}

// The shell cyfr login holds runs with the session for its home alone,
// any earlier unlock's variables gone; its exit locks the device, after
// it ends, and cyfr login exits with its status.
func TestHoldShell_TheShellsExitLocksAndIsTheStatus(t *testing.T) {
	envFile := filepath.Join(t.TempDir(), "env")
	t.Setenv("SHELL", shellScript(t, "env > "+envFile+"; exit 3"))
	t.Setenv(sessionEnv, "AN-EARLIER-SESSION")
	t.Setenv(shellPagesEnv, "1")
	dev := newFakeDevice(shell.View{Page: shell.PageUnlocked}, nil)

	err := holdShell(dev, nil, "https://alice.example", "TOKEN-1", make(chan struct{}))
	var status handedOver
	if !errors.As(err, &status) || status.status != 3 || dev.locks != 1 {
		t.Fatalf("hold: %v, locks %d", err, dev.locks)
	}
	env, _ := os.ReadFile(envFile)
	for _, want := range []string{sessionEnv + "=TOKEN-1\n", sessionHomeEnv + "=https://alice.example\n", shellPIDEnv + "=" + strconv.Itoa(os.Getpid()) + "\n"} {
		if !bytes.Contains(env, []byte(want)) {
			t.Errorf("the shell's environment lacks %q", want)
		}
	}
	if bytes.Contains(env, []byte("AN-EARLIER-SESSION")) || bytes.Contains(env, []byte(shellPagesEnv+"=")) {
		t.Errorf("an earlier unlock's variables reached the shell:\n%s", env)
	}
}

// cyfr logout's SIGTERM locks the device first and then hangs up the
// shell; Ctrl-C reaching cyfr login is the shell's and locks nothing; a
// channel the home ends is said, and the shell goes on until it exits.
func TestHoldShell_LogoutLocksAndHangsUpTheShell(t *testing.T) {
	marker := filepath.Join(t.TempDir(), "hung-up")
	t.Setenv("SHELL", shellScript(t, "trap 'echo up > "+marker+"; exit 0' HUP; while :; do sleep 0.05; done"))
	dev := newFakeDevice(shell.View{Page: shell.PageUnlocked}, nil)
	done := make(chan error, 1)
	go func() { done <- holdShell(dev, nil, "https://alice.example", "TOKEN-1", make(chan struct{})) }()

	time.Sleep(300 * time.Millisecond)
	_ = syscall.Kill(os.Getpid(), syscall.SIGINT)
	time.Sleep(200 * time.Millisecond)
	dev.mu.Lock()
	locks := dev.locks
	dev.mu.Unlock()
	if locks != 0 {
		// Nothing listens for the SIGTERM below once the hold ended.
		t.Fatalf("Ctrl-C locked the device")
	}
	_ = syscall.Kill(os.Getpid(), syscall.SIGTERM)
	select {
	case <-done:
	case <-time.After(10 * time.Second):
		t.Fatal("the shell was not hung up")
	}
	if _, err := os.Stat(marker); err != nil || dev.locks < 1 {
		t.Errorf("hung up %v, locks %d", err, dev.locks)
	}
}

func TestHoldShell_ALockByTheHomeIsSaid(t *testing.T) {
	t.Setenv("SHELL", shellScript(t, "sleep 0.5; exit 0"))
	dev := newFakeDevice(shell.View{Page: shell.PageLocked, Notice: "CYFR could not be reached."}, nil)
	locked := make(chan struct{})
	close(locked)
	var err error
	stderr := captureStderr(t, func() { err = holdShell(dev, nil, "https://alice.example", "TOKEN-1", locked) })
	if err != nil || !strings.Contains(stderr, "CYFR locked this command line: CYFR could not be reached.") {
		t.Fatalf("hold: %v\n%s", err, stderr)
	}
}

// cyfr logout outside cyfr login's shell has nothing to lock, and it
// signals no process that is not cyfr login.
func TestLogout_SignalsOnlyCyfrLogin(t *testing.T) {
	withContexts(t, "home", map[string]*config.Context{"home": {URL: "https://alice.example"}})
	if _, err := runCommand(t, t.Context(), "logout"); err == nil || !strings.Contains(err.Error(), "nothing to lock") {
		t.Errorf("logout outside: %v", err)
	}
	other := exec.Command("sleep", "5")
	if err := other.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = other.Process.Kill(); _ = other.Wait() })
	if err := endShell(strconv.Itoa(other.Process.Pid)); err == nil {
		t.Error("logout signalled a process that is not cyfr login")
	}
	if err := endShell("1"); err == nil {
		t.Error("logout signalled init")
	}
}
