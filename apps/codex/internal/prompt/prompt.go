// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package prompt

import (
	"context"
	"errors"
	"io"
	"os"

	"charm.land/huh/v2"
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

// formInput and formOutput are where a form reads its keys and draws,
// the terminal when nil (UseTerminal).
var (
	formInput  io.Reader
	formOutput io.Writer
)

// UseTerminal stands in and out for the terminal every form reads its
// keys from and draws on, until the restore it answers is called; for
// tests.
func UseTerminal(in io.Reader, out io.Writer) (restore func()) {
	savedIn, savedOut := formInput, formOutput
	formInput, formOutput = in, out
	return func() { formInput, formOutput = savedIn, savedOut }
}

// newForm wraps huh.NewForm with standard settings.
func newForm(groups ...*huh.Group) *huh.Form {
	form := huh.NewForm(groups...)
	if formInput != nil {
		form = form.WithInput(formInput)
	}
	if formOutput != nil {
		form = form.WithOutput(formOutput)
	}
	return form
}

// run runs form until it is submitted or aborted, or ctx ends. Ctrl-C in
// the form reaches it as a key, since the form holds the terminal in raw
// mode, and answers huh.ErrUserAborted; ctx ending, the signals Main
// cancels the command's context on, answers ErrAborted.
func run(ctx context.Context, form *huh.Form) error {
	err := form.RunWithContext(ctx)
	if ctx.Err() != nil {
		return ErrAborted
	}
	return err
}
