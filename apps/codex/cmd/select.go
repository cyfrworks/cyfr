// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"context"
	"errors"
	"fmt"

	"github.com/cyfr/codex/internal/prompt"
)

// selector describes how a command resolves the subject it acts on when the
// user names it either as a positional argument or through an interactive
// picker. The strings are the command's own user-facing copy — pickTarget
// changes none of it.
type selector struct {
	// Title is the picker's prompt (e.g. "Select a key to revoke").
	Title string
	// Fetch supplies the options to pick from. Errors go through
	// handleToolError, matching what the call sites did by hand.
	Fetch func(ctx context.Context) ([]prompt.Option, error)
	// Empty is the error message when Fetch returns no options.
	Empty string
	// Usage is the error message when there is neither an argument nor an
	// interactive terminal to ask on.
	Usage string
	// Normalize, when set, post-processes a positionally-given argument
	// (e.g. resolving a version-less component ref). Picker values are
	// already normalized by construction and skip it.
	Normalize func(ctx context.Context, arg string) (string, error)
	// Confirm, when non-empty, is a fmt template rendered with the picked
	// value and put to the user as a yes/no gate after the picker.
	Confirm string
}

// pickTarget resolves a command's subject: the first argument when one was
// given, otherwise an interactive pick from sel.Fetch's options.
//
// Declining sel.Confirm prints "Cancelled." and returns "" with a nil error —
// callers treat an empty name as "nothing to do" and return nil (exit 0).
// Aborting a prompt (Ctrl+C) returns prompt.ErrAborted, which main maps to
// exit code 130.
func pickTarget(ctx context.Context, args []string, sel selector) (string, error) {
	switch {
	case len(args) >= 1:
		if sel.Normalize != nil {
			return sel.Normalize(ctx, args[0])
		}
		return args[0], nil

	case prompt.IsInteractive(flagNoInteractive):
		opts, err := sel.Fetch(ctx)
		if err != nil {
			return "", handleToolError(err)
		}
		if len(opts) == 0 {
			return "", errors.New(sel.Empty)
		}

		selected, err := prompt.SelectOne(sel.Title, opts)
		if err != nil {
			if prompt.IsAborted(err) {
				return "", prompt.ErrAborted
			}
			return "", fmt.Errorf("Prompt failed: %w", err)
		}

		if sel.Confirm != "" {
			confirmed, err := prompt.Confirm(fmt.Sprintf(sel.Confirm, selected))
			if err != nil {
				if prompt.IsAborted(err) {
					return "", prompt.ErrAborted
				}
				return "", fmt.Errorf("Prompt failed: %w", err)
			}
			if !confirmed {
				fmt.Println("Cancelled.")
				return "", nil
			}
		}
		return selected, nil

	default:
		return "", errors.New(sel.Usage)
	}
}
