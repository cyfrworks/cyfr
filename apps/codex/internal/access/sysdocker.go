// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package access

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"
)

// ErrDeadline is a docker call killed at its deadline. The call may have
// had effects the daemon still applies; the next stop and verify reads
// what they were.
var ErrDeadline = errors.New("access: the docker call was killed at its deadline")

// CallError is a docker call that did not exit 0. It carries no argument
// and no output, which may hold a secret the caller passed.
type CallError struct {
	ExitCode int
	Deadline bool
}

func (c *CallError) Error() string {
	if c.Deadline {
		return ErrDeadline.Error()
	}
	return fmt.Sprintf("docker exited with status %d", c.ExitCode)
}

func (c *CallError) Is(target error) bool { return c.Deadline && target == ErrDeadline }

// systemDocker runs the docker binary on this machine. Every call's
// environment is cyfr's with every COMPOSE_* variable removed, DOCKER_*
// kept; it runs in the project directory, in a process group of its own,
// bounded by its deadline (StartDeadline when the call names none).
// While the engine holds the lock, a Unix call runs under the watchdog,
// which inherits the lock's descriptor and passes it to docker, so the
// lock outlives cyfr until the call ends or its deadline kills it; a
// Windows call runs in a kill-on-close Job Object of its own, which
// kills it, and everything it started, with cyfr.
type systemDocker struct {
	e *Engine
	// binary is the docker command; watchdog the argv that runs
	// WatchdogMain, nil until it is first needed.
	binary   string
	watchdog []string
	environ  func() []string
}

func newSystemDocker(e *Engine) *systemDocker {
	return &systemDocker{e: e, binary: "docker", environ: os.Environ}
}

// WatchdogCommand is the argv after cyfr's own path that runs
// WatchdogMain: the hidden `cyfr internal docker-run`.
var WatchdogCommand = []string{"internal", "docker-run"}

func (s *systemDocker) Run(ctx context.Context, c Call) (Result, error) {
	deadline := c.Deadline
	if deadline <= 0 {
		deadline = StartDeadline
	}
	bin, err := exec.LookPath(s.binary)
	if err != nil {
		return Result{ExitCode: -1}, fmt.Errorf("access: %w", err)
	}
	var stdout, stderr bytes.Buffer
	streams := func(cmd *exec.Cmd) {
		cmd.Dir = s.e.dir
		cmd.Env = sanitizedEnv(s.environ())
		cmd.Stdin = c.Stdin
		cmd.Stdout, cmd.Stderr = c.Stdout, c.Stderr
		if cmd.Stdout == nil {
			cmd.Stdout = &stdout
		}
		if cmd.Stderr == nil {
			cmd.Stderr = &stderr
		}
	}
	code, err := s.run(ctx, bin, c.Args, deadline, streams)
	return Result{ExitCode: code, Stdout: stdout.Bytes(), Stderr: stderr.Bytes()}, err
}

// sanitizedEnv is env without any COMPOSE_* variable, matched without
// case, as Windows matches names.
func sanitizedEnv(env []string) []string {
	out := make([]string, 0, len(env))
	for _, kv := range env {
		name, _, _ := strings.Cut(kv, "=")
		if strings.HasPrefix(strings.ToUpper(name), "COMPOSE_") {
			continue
		}
		out = append(out, kv)
	}
	return out
}

// watchdogArgv is the argv that runs WatchdogMain from this executable.
func (s *systemDocker) watchdogArgv() ([]string, error) {
	if s.watchdog != nil {
		return s.watchdog, nil
	}
	exe, err := os.Executable()
	if err != nil {
		return nil, fmt.Errorf("access: find cyfr's own executable for the docker watchdog: %w", err)
	}
	return append([]string{exe}, WatchdogCommand...), nil
}

// exitStatus is a finished command's exit status and the error a call
// answers for it.
func exitStatus(err error, deadlineHit bool) (int, error) {
	if err == nil {
		return 0, nil
	}
	var exit *exec.ExitError
	if errors.As(err, &exit) {
		code := exit.ExitCode()
		if deadlineHit || code == watchdogDeadline {
			return code, &CallError{ExitCode: code, Deadline: true}
		}
		return code, &CallError{ExitCode: code}
	}
	return -1, err
}

// watchdogDeadline is the watchdog's exit status for a call it killed at
// its deadline, timeout(1)'s.
const watchdogDeadline = 124

// waitGrace bounds how long a killed call's output may take to drain.
const waitGrace = 10 * time.Second
