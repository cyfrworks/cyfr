// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package prompt

import (
	"errors"
	"os"

	"github.com/charmbracelet/huh"
	"golang.org/x/term"
)

// ErrNotInteractive is returned when interactive mode is required but not available.
var ErrNotInteractive = errors.New("interactive mode not available (no TTY)")

// ErrAborted is the sentinel commands return when the user aborts a prompt
// (Ctrl+C). main maps it to exit code 130 without printing an error, and it
// unwinds through defers and cleanup hooks — unlike the os.Exit(130) it
// replaces.
var ErrAborted = errors.New("aborted")

// IsInteractive returns true if stdin and stdout are terminals and
// interactive mode has not been disabled via flag or environment variable.
func IsInteractive(noInteractiveFlag bool) bool {
	if noInteractiveFlag {
		return false
	}
	if os.Getenv("CYFR_NO_INTERACTIVE") != "" {
		return false
	}
	return term.IsTerminal(int(os.Stdin.Fd())) && term.IsTerminal(int(os.Stdout.Fd()))
}

// IsAborted returns true if the error is a user abort (Ctrl+C) — either the
// raw huh error a prompt returns or the ErrAborted sentinel commands wrap it in.
func IsAborted(err error) bool {
	return errors.Is(err, huh.ErrUserAborted) || errors.Is(err, ErrAborted)
}

// newForm wraps huh.NewForm with standard settings.
func newForm(groups ...*huh.Group) *huh.Form {
	return huh.NewForm(groups...)
}
