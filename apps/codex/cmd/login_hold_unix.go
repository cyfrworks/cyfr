// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build !windows

package cmd

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"

	"github.com/cyfr/codex/internal/shell"
)

// holdShell starts the person's shell ($SHELL, else /bin/sh) on this
// terminal with the session in its environment, and holds the unlock
// while it runs: the device channel reports every 30 seconds, which alone
// keeps the session (and any browser session cyfr open opened through
// this unlock) alive at the home, and the shell's loopback pages serve
// cyfr open, Prism's Lock and its Confirm on this device.
//
// The shell's exit (the terminal closed, exit, end of input), a SIGTERM
// (cyfr logout) or a SIGHUP locks: each held session's lock proof is
// submitted, the channel closed and the key erased (shell.Shell.Lock), and
// a shell still running is hung up. Ctrl-C and Ctrl-\ are the shell's,
// never this process's. A channel the home ends, or a connection lost,
// locks too; the shell then keeps running with a session that opens
// nothing, and says so. A process killed before it locks leaves sessions
// that expire within 60 seconds at the home, as nothing reports for them.
func holdShell(sh device, server *shell.Server, address, session string, locked <-chan struct{}) error {
	pagesCtx, stopPages := context.WithCancel(context.Background())
	defer stopPages()
	pages := false
	if server != nil {
		if ln, err := listenPages(); err == nil {
			pages = true
			go func() { _ = server.ServeOn(pagesCtx, ln) }()
		}
	}

	path := os.Getenv("SHELL")
	if path == "" || !filepath.IsAbs(path) {
		path = "/bin/sh"
	}
	child := exec.Command(path)
	child.Stdin, child.Stdout, child.Stderr = os.Stdin, os.Stdout, os.Stderr
	child.Env = shellEnv(os.Environ(), address, session, os.Getpid(), pages)

	// Notified, not ignored: an ignored signal would stay ignored in the
	// shell and every command it runs.
	sigs := make(chan os.Signal, 4)
	signal.Notify(sigs, os.Interrupt, syscall.SIGQUIT, syscall.SIGTERM, syscall.SIGHUP)
	defer signal.Stop(sigs)

	note := ""
	if pages {
		note = " cyfr open opens CYFR in your browser through it."
	}
	fmt.Printf("Unlocked. This shell holds your CYFR session: exit it, or run cyfr logout, to lock.%s\n", note)
	if err := child.Start(); err != nil {
		sh.Lock("")
		return fmt.Errorf("Could not start your shell %s (%v), so this command line locked again.", path, err)
	}
	done := make(chan error, 1)
	go func() { done <- child.Wait() }()

	ending := false
	for {
		select {
		case err := <-done:
			stopPages()
			sh.Lock("")
			fmt.Println("Locked: this command line's CYFR session ended.")
			return shellExit(err)
		case s := <-sigs:
			if s == os.Interrupt || s == syscall.SIGQUIT || ending {
				continue
			}
			ending = true
			stopPages()
			sh.Lock("")
			_ = child.Process.Signal(syscall.SIGHUP)
		case <-locked:
			locked = nil
			stopPages()
			if !ending {
				fmt.Fprintf(os.Stderr, "\nCYFR locked this command line: %s Commands here act as no one now; exit this shell, and cyfr login unlocks again.\n",
					strings.TrimSpace(sh.View().Notice))
			}
		}
	}
}

// listenPages takes the shell's loopback listener; a test stands in for
// it.
var listenPages = shell.ListenLoopback

// shellEnv is the environment the shell runs with: the caller's, without
// any earlier unlock's variables, and this unlock's.
func shellEnv(env []string, address, session string, pid int, pages bool) []string {
	out := make([]string, 0, len(env)+4)
	for _, kv := range env {
		name, _, _ := strings.Cut(kv, "=")
		switch name {
		case sessionEnv, sessionHomeEnv, shellPIDEnv, shellPagesEnv:
			continue
		}
		out = append(out, kv)
	}
	out = append(out, sessionEnv+"="+session, sessionHomeEnv+"="+address, shellPIDEnv+"="+strconv.Itoa(pid))
	if pages {
		out = append(out, shellPagesEnv+"=1")
	}
	return out
}

// shellExit is the shell's exit as this command's: its status, which
// cyfr login exits with, printing nothing more.
func shellExit(err error) error {
	var exit *exec.ExitError
	if errors.As(err, &exit) {
		if status := exit.ExitCode(); status > 0 {
			return handedOver{status: status}
		}
		return handedOver{status: 128 + int(syscall.SIGHUP)}
	}
	return err
}

// endShell asks the cyfr login holding this terminal's shell, process
// pid, to lock (SIGTERM). A process the system does not show to run this
// program (sameProgram) is not signalled.
func endShell(pid string) error {
	n, err := strconv.Atoi(pid)
	if err != nil || n <= 1 {
		return errors.New("the shell names no cyfr login")
	}
	self, err := os.Executable()
	if err != nil {
		return err
	}
	if !sameProgram(n, self) {
		return errors.New("the process the shell names is not cyfr login")
	}
	return syscall.Kill(n, syscall.SIGTERM)
}
