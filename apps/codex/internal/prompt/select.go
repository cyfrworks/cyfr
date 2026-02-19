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

// SelectMany presents a multi-select prompt with filtering and returns selected values.
// preSelected contains values that should be checked by default.
func SelectMany(title string, options []Option, preSelected ...string) ([]string, error) {
	var selected []string

	pre := make(map[string]bool, len(preSelected))
	for _, v := range preSelected {
		pre[v] = true
	}

	huhOpts := make([]huh.Option[string], len(options))
	for i, o := range options {
		opt := huh.NewOption(o.Label, o.Value)
		if pre[o.Value] {
			opt = opt.Selected(true)
		}
		huhOpts[i] = opt
	}

	err := newForm(
		huh.NewGroup(
			huh.NewMultiSelect[string]().
				Title(title).
				Description("space to select, enter to confirm").
				Options(huhOpts...).
				Value(&selected).
				Height(12),
		),
	).Run()
	if err != nil {
		return nil, err
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
func InputText(title, placeholder string) (string, error) {
	var value string

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

// InputSecret presents a masked text input prompt and returns the entered value.
func InputSecret(title, placeholder string) (string, error) {
	var value string

	input := huh.NewInput().
		Title(title).
		Value(&value).
		EchoMode(huh.EchoModePassword)
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
