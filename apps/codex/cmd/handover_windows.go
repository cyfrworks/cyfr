// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build windows

package cmd

import (
	"errors"
	"os"
	"os/exec"
)

// continueAs runs the program at path with args as a child holding this
// process's environment and console, waits for it and answers its exit
// status: Windows has no exec, and the program file was renamed aside
// rather than replaced in place. The child is not tied to this process's
// context, so a Ctrl-C, which the console delivers to both, is the
// child's to handle.
func continueAs(path string, args []string) (int, error) {
	c := exec.Command(path, args[1:]...)
	c.Stdin, c.Stdout, c.Stderr, c.Env = os.Stdin, os.Stdout, os.Stderr, os.Environ()
	err := c.Run()
	var exit *exec.ExitError
	if errors.As(err, &exit) {
		return exit.ExitCode(), nil
	}
	return 0, err
}
