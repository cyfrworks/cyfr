// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package prompt

import (
	"github.com/charmbracelet/huh"
)

// Option represents a selectable item with a display label and underlying value.
type Option struct {
	Label string
	Value string
}

// SelectOne presents a single-select prompt with filtering and returns the chosen value.
func SelectOne(title string, options []Option) (string, error) {
	var selected string

	huhOpts := make([]huh.Option[string], len(options))
	for i, o := range options {
		huhOpts[i] = huh.NewOption(o.Label, o.Value)
	}

	err := newForm(
		huh.NewGroup(
			huh.NewSelect[string]().
				Title(title).
				Options(huhOpts...).
				Value(&selected).
				Filtering(true).
				Height(10),
		),
	).Run()
	if err != nil {
		return "", err
	}
	return selected, nil
}

// Confirm presents a yes/no confirmation prompt.
func Confirm(title string) (bool, error) {
	var confirmed bool

	err := newForm(
		huh.NewGroup(
			huh.NewConfirm().
				Title(title).
				Affirmative("Yes").
				Negative("No").
				Value(&confirmed),
		),
	).Run()
	if err != nil {
		return false, err
	}
	return confirmed, nil
}

// InputText presents a text input prompt and returns the entered value.
// If initialValue is non-empty, the field is pre-filled.
func InputText(title, placeholder string, initialValue ...string) (string, error) {
	var value string
	if len(initialValue) > 0 {
		value = initialValue[0]
	}

	input := huh.NewInput().
		Title(title).
		Value(&value)
	if placeholder != "" {
		input = input.Placeholder(placeholder)
	}

	err := newForm(
		huh.NewGroup(input),
	).Run()
	if err != nil {
		return "", err
	}
	return value, nil
}
