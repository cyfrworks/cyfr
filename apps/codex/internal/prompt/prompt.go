package prompt

import (
	"errors"
	"os"

	"github.com/charmbracelet/huh"
	"golang.org/x/term"
)

// ErrNotInteractive is returned when interactive mode is required but not available.
var ErrNotInteractive = errors.New("interactive mode not available (no TTY)")

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

// IsAborted returns true if the error is a user abort (Ctrl+C).
func IsAborted(err error) bool {
	return errors.Is(err, huh.ErrUserAborted)
}

// newForm wraps huh.NewForm with standard settings.
func newForm(groups ...*huh.Group) *huh.Form {
	return huh.NewForm(groups...)
}
