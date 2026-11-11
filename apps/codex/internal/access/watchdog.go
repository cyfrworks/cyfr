// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package access

import (
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"strconv"
	"syscall"
	"time"
)

// watchdogArgs are the watchdog's options before the docker command:
// the call's deadline, and, when it carries the lock, the lock's
// descriptor and the descriptor its go-ahead arrives on.
func watchdogArgs(deadline time.Duration, lock bool) []string {
	args := []string{"--deadline", deadline.String()}
	if lock {
		args = append(args, "--lock-fd", "3", "--go-fd", "4")
	}
	return append(args, "--")
}

// watchdogMain is WatchdogMain: `--deadline D [--lock-fd N] [--go-fd N]
// -- docker args…`. It runs docker in a process group of its own, passing
// it the lock's descriptor, and kills that group at the deadline (exit
// 124) or when it is asked to stop. It exits with docker's status; 125
// when it could not run it. Given --go-fd, it starts docker only once a
// byte arrives there, which its parent writes after the holder record
// names this watchdog: the descriptor ending without one (the parent died
// first, or could not write the record) ends the watchdog with 125 and
// docker never run, so the lock is free again. The deadline runs from
// before that wait. Once docker runs, its parent's death does not end it:
// the lock stays held until docker ends, at the latest at the deadline.
// Docker's own
// streams pass through to the engine, which says them only by
// diagnosis; the watchdog's own lines are redacted with the .env of the
// project directory it runs in (redactor).
func watchdogMain(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	say := func(format string, a ...any) {
		env, _ := os.ReadFile(".env")
		fmt.Fprint(stderr, redactorFor(env, nil).text(fmt.Sprintf(format, a...)))
	}
	var deadline time.Duration
	lockFD, goFD := -1, -1
	i := 0
	for ; i < len(args) && args[i] != "--"; i++ {
		switch args[i] {
		case "--deadline":
			if i+1 < len(args) {
				deadline, _ = time.ParseDuration(args[i+1])
			}
			i++
		case "--lock-fd":
			if i+1 < len(args) {
				lockFD, _ = strconv.Atoi(args[i+1])
			}
			i++
		case "--go-fd":
			if i+1 < len(args) {
				goFD, _ = strconv.Atoi(args[i+1])
			}
			i++
		default:
			say("cyfr internal docker-run: unknown option %q\n", args[i])
			return 125
		}
	}
	if i >= len(args)-1 || deadline <= 0 {
		say("usage: cyfr internal docker-run --deadline DURATION [--lock-fd N] [--go-fd N] -- docker ARGS...\n")
		return 125
	}
	command := args[i+1:]

	// A terminal's hangup, or the parent's group being signalled, must
	// not end the call early: only the deadline and an explicit stop do.
	signal.Ignore(syscall.SIGHUP)
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGTERM, syscall.SIGINT)
	defer signal.Stop(stop)
	timer := time.NewTimer(deadline)
	defer timer.Stop()

	if goFD >= 0 {
		ahead := os.NewFile(uintptr(goFD), "go")
		went := make(chan bool, 1)
		go func() {
			var b [1]byte
			n, _ := ahead.Read(b[:])
			went <- n == 1
		}()
		select {
		case ok := <-went:
			// Closed before docker starts, which would inherit it.
			ahead.Close()
			if !ok {
				say("cyfr internal docker-run: the command that started this call ended before it recorded it; docker was not run\n")
				return 125
			}
		case <-timer.C:
			say("cyfr internal docker-run: the %s deadline passed before docker was started\n", deadline)
			return watchdogDeadline
		case <-stop:
			return 143
		}
	}

	cmd := exec.Command(command[0], command[1:]...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = stdin, stdout, stderr
	if lockFD >= 0 {
		cmd.ExtraFiles = []*os.File{os.NewFile(uintptr(lockFD), "lock")}
	}
	ownGroup(cmd)
	if err := cmd.Start(); err != nil {
		say("cyfr internal docker-run: %v\n", err)
		var exit *exec.Error
		if errors.As(err, &exit) {
			return 127
		}
		return 125
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	var err error
	killed := false
	select {
	case err = <-done:
	case <-timer.C:
		killGroup(cmd)
		killed = true
		err = <-done
	case <-stop:
		killGroup(cmd)
		err = <-done
		return 143
	}
	if killed {
		say("cyfr internal docker-run: killed docker at its %s deadline\n", deadline)
		return watchdogDeadline
	}
	var exit *exec.ExitError
	if errors.As(err, &exit) {
		if code := exit.ExitCode(); code >= 0 {
			return code
		}
		return 128 + 9
	}
	if err != nil {
		return 125
	}
	return 0
}
