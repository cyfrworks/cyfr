// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package brainwire

import (
	"errors"
	"fmt"
	"io"
	"os/exec"
	"syscall"
	"time"
)

const (
	// MaxHarnessLineBytes bounds one line of a harness's output: a tool's
	// result in a line, the largest either harness writes, and room beyond.
	MaxHarnessLineBytes = 64 << 20
	// closeWait bounds the harness's own end after its input closes, before
	// it is killed.
	closeWait = 5 * time.Second
	// termAfter is how long the harness is given to end by itself after
	// its input closes before it is asked to, with a TERM to its group.
	termAfter = 2 * time.Second
)

// Process is one running harness process. Each line of its output arrives
// on Lines, nil for one past MaxHarnessLineBytes, after which nothing more
// is read; Done is closed once the process has ended, its status in
// Status.
type Process struct {
	cmd    *exec.Cmd
	stdin  io.WriteCloser
	Lines  chan []byte
	Done   chan struct{}
	Status int
	// Expected is set once the driver knows the process ends by itself (a
	// harness that holds no transcript of the session named): its end ends
	// nothing more.
	Expected bool
}

// ErrNotStarted is all the wire is told of a harness that did not start.
// Why it did not, the command's path and the system's words, may name the
// folder, so it is the driver's standard error's alone.
var ErrNotStarted = errors.New("it did not start")

// Spawn starts `argv`, its standard error the driver's, which the box keeps
// for the person and never hands a thread, in its own process group, so a
// server it starts ends with it, and it ends with the driver. A start that
// fails is said on the driver's standard error and answers ErrNotStarted.
func (c *Conn) Spawn(argv []string) (*Process, error) {
	p, err := spawn(argv, c.ErrOut)
	if err != nil {
		fmt.Fprintf(c.ErrOut, "%s: the harness did not start: %v\n", c.name, err)
		return nil, ErrNotStarted
	}
	return p, nil
}

func spawn(argv []string, errOut io.Writer) (*Process, error) {
	path, err := exec.LookPath(argv[0])
	if err != nil {
		return nil, err
	}
	cmd := exec.Command(path, argv[1:]...)
	cmd.Args = argv
	cmd.Stderr = errOut
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true, Pdeathsig: syscall.SIGKILL}
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	p := &Process{cmd: cmd, stdin: stdin, Lines: make(chan []byte), Done: make(chan struct{})}
	stopped := make(chan struct{})
	go func() {
		defer close(stopped)
		reader := NewLineReader(stdout, MaxHarnessLineBytes)
		for {
			line, err := reader.Next()
			if line != nil || errors.Is(err, ErrLineTooLong) {
				p.Lines <- line
			}
			if err != nil {
				return
			}
		}
	}()
	go func() {
		<-stopped
		if err := cmd.Wait(); err != nil {
			p.Status = 1
			var exit *exec.ExitError
			if errors.As(err, &exit) && exit.ExitCode() > 0 {
				p.Status = exit.ExitCode()
			}
		}
		close(p.Done)
	}()
	return p, nil
}

// Write writes one line to the harness: a harness that does not take it
// has ended, which ends the driver.
func (p *Process) Write(line []byte) error {
	if _, err := p.stdin.Write(append(line, '\n')); err != nil {
		return &Fatal{1, "the harness's input: " + err.Error()}
	}
	return nil
}

// WriteUnchecked writes one line and ignores a failure: the process's
// end, which it may have reached already, says what happened.
func (p *Process) WriteUnchecked(line []byte) {
	_, _ = p.stdin.Write(append(line, '\n'))
}

// Stop writes the harness its last lines, `farewell` (Codex's
// turn/interrupt), closes its input and waits for its end, then ends its
// process group, so a server it started ends with it. A harness still
// running termAfter later is asked to end, a TERM to its group (Claude Code
// 2.1.323 and Codex 0.169.0 each end within a second of one, aq-drivers),
// and one still running at closeWait is killed. Stop returns only once the
// harness has ended, whichever way.
func (p *Process) Stop(farewell ...[]byte) {
	pgid := p.cmd.Process.Pid
	// Both bounds are armed before anything is written: a harness that
	// never reads its input holds the write, never the bounds. The write
	// ends once the harness does, its pipe's reader gone.
	term := time.After(termAfter)
	deadline := time.After(closeWait)
	go func() {
		for _, line := range farewell {
			if _, err := p.stdin.Write(append(line, '\n')); err != nil {
				break
			}
		}
		_ = p.stdin.Close()
	}()
	for {
		select {
		case <-p.Lines:
		case <-p.Done:
			_ = syscall.Kill(-pgid, syscall.SIGKILL)
			return
		case <-term:
			_ = syscall.Kill(-pgid, syscall.SIGTERM)
		case <-deadline:
			_ = syscall.Kill(-pgid, syscall.SIGKILL)
		}
	}
}
