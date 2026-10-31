// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package install

import (
	"errors"
	"fmt"
	"slices"
	"strings"
)

// Requirements names what actions install, for the sentences that say
// what was or was not done: the packages, the Docker service and the
// account's group.
func Requirements(p Policy, actions []Action) string {
	var parts []string
	for _, a := range actions {
		switch a.Kind {
		case AptInstall:
			parts = append(parts, a.Packages...)
		case DockerEnable:
			parts = append(parts, "the running Docker service")
		case GroupAdd:
			parts = append(parts, fmt.Sprintf("%s's membership of the %s group", a.Account, p.Docker.Group))
		case DpkgConfigure:
			parts = append(parts, "the interrupted package installation's repair")
		}
	}
	return joinAnd(parts)
}

// Completed says what changed between two observations of the machine:
// packages dpkg now reports installed, or left partly installed, the
// Docker service now running and enabled, the account now in the docker
// group. "Nothing was
// installed." is said only when nothing changed.
func Completed(p Policy, before, after Facts) string {
	var done []string
	if before.Interrupted && !after.Interrupted {
		done = append(done, "finished the interrupted package installation")
	}
	var installed []string
	for _, pkg := range p.Docker.Packages {
		if !before.installed(pkg.Package) && after.installed(pkg.Package) {
			installed = append(installed, pkg.Package)
		}
	}
	if len(installed) > 0 {
		done = append(done, "installed "+joinAnd(installed))
	}
	// A package dpkg holds in another state than before, and not
	// installed: unpacked, half-installed or half-configured, as an
	// interrupted installation leaves it.
	var partly []string
	for _, pkg := range p.Docker.Packages {
		if state := after.Packages[pkg.Package]; state != before.Packages[pkg.Package] && state != "" && state != "installed" {
			partly = append(partly, pkg.Package)
		}
	}
	switch {
	case len(partly) > 0:
		done = append(done, "left "+joinAnd(partly)+" partly installed")
	case after.Interrupted && !before.Interrupted:
		// dpkg holds another package unfinished: a dependency the
		// install brought in, which the policy does not name.
		done = append(done, "left a package installation unfinished")
	}
	if !(before.Docker.Service == "active" && before.Docker.Enabled) && after.Docker.Service == "active" && after.Docker.Enabled {
		done = append(done, "started the Docker service")
	}
	if !before.Account.Member && after.Account.Member {
		done = append(done, fmt.Sprintf("added %s to the %s group", after.Account.Name, p.Docker.Group))
	}
	if len(done) == 0 {
		return "Nothing was installed."
	}
	return "CYFR " + joinAnd(done) + "."
}

// Refusal is the sentence of a decision CYFR does not act on, with what
// was completed before it and command, the one to run again.
func Refusal(p Policy, d Decision, completed, command string) string {
	switch d.Cause {
	case CauseUniverse:
		return fmt.Sprintf("Ubuntu's universe archive is not enabled. Run `%s`, then run %s again.", p.Universe.Command, command)
	case CauseProvider:
		return fmt.Sprintf("CYFR cannot use this machine's Docker because %s, and it does not replace another provider's Docker. %s Update Docker to meet it, then run %s again.", d.Detail, completed, command)
	case CauseContext:
		return fmt.Sprintf("CYFR cannot use this machine's Docker because %s. %s Switch to this machine's own daemon (`docker context use default`), then run %s again.", d.Detail, completed, command)
	case CauseSecurity:
		return fmt.Sprintf("CYFR cannot run its components here because %s, and it does not change security settings. %s Turn it on in the system's own settings, then run %s again.", d.Detail, completed, command)
	case CauseRefresh:
		return fmt.Sprintf("CYFR cannot use Docker yet because %s. %s Run `newgrp docker`, or log out and in again, then run %s again.", d.Detail, completed, command)
	}
	return fmt.Sprintf("%s: %s", d.Cause, d.Detail)
}

// NoSudo, NoAgreement and Declined are the sentences of an install that
// could not be agreed or elevated.
func NoSudo(requirements, completed, command string) string {
	return fmt.Sprintf("This account cannot run sudo, so CYFR cannot install %s. %s Run %s from an account that can install software.", requirements, completed, command)
}

// SudoCause is why sudo did not run the root entry, read from what sudo
// printed (its messages in sudo-rs and in sudo).
type SudoCause int

const (
	SudoUnknown SudoCause = iota
	// SudoNotAllowed: sudo's policy does not let the account run it.
	SudoNotAllowed
	// SudoNeedsPassword: sudo wants a password and none can be typed.
	SudoNeedsPassword
	// SudoWrongPassword: the password typed was refused, each time.
	SudoWrongPassword
)

// ReadSudoCause reads, in what sudo printed, the policy's words for why
// it ran nothing, case-insensitively and in the policy's order; sudo runs
// with LC_ALL=C, so its words are the ones the policy names.
func ReadSudoCause(p Policy, printed string) SudoCause {
	text := strings.ToLower(printed)
	has := func(words []string) bool {
		return slices.ContainsFunc(words, func(w string) bool { return strings.Contains(text, strings.ToLower(w)) })
	}
	switch {
	case has(p.Sudo.WrongPassword):
		return SudoWrongPassword
	case has(p.Sudo.NeedsPassword):
		return SudoNeedsPassword
	case has(p.Sudo.NotAllowed):
		return SudoNotAllowed
	}
	return SudoUnknown
}

// SudoRefused is the sentence of a sudo that ran nothing, by its cause.
func SudoRefused(cause SudoCause, requirements, completed, command string) string {
	switch cause {
	case SudoNeedsPassword:
		return fmt.Sprintf("sudo needs this account's password, and without a terminal there is nowhere to type it, so CYFR cannot install %s. %s Run %s in a terminal, or give this account sudo without a password prompt.", requirements, completed, command)
	case SudoWrongPassword:
		return fmt.Sprintf("sudo did not accept the password, so CYFR cannot install %s. %s Run %s again and type this account's password.", requirements, completed, command)
	case SudoNotAllowed:
		return NoSudo(requirements, completed, command)
	}
	return fmt.Sprintf("sudo did not run CYFR's installer, so CYFR cannot install %s. %s Run %s again once sudo works for this account.", requirements, completed, command)
}

// UnderSudo is the sentence of cyfr init run as root through sudo where it
// would install requirements: done so, it would set CYFR up for root.
func UnderSudo(requirements, account string) string {
	return fmt.Sprintf("`sudo cyfr init` would install %s and set CYFR up for root, not for %s. Nothing was changed. Run `cyfr init` without sudo: it asks for the administrator password itself when it needs one.", requirements, account)
}

func NoAgreement(requirements, command string) string {
	return fmt.Sprintf("Installing %s needs your agreement in a terminal. Nothing was installed. Run %s in a terminal, or with --yes to agree to the changes it shows.", requirements, command)
}

func Declined(requirements, command string) string {
	return fmt.Sprintf("You chose not to install %s. Nothing was installed. Run %s again when you want to continue.", requirements, command)
}

// Failure is the sentence of an Apply that stopped, with what was
// completed before it.
func Failure(p Policy, err error, completed, command string) string {
	var lock LockError
	var stale StaleError
	var refused RefusedError
	var candidate CandidateError
	var step StepError
	switch {
	case errors.As(err, &lock):
		what := map[Lock]string{
			LockInstall: "Another CYFR installation",
			LockLists:   "A package-list update",
			LockDpkg:    "A package installation",
		}[lock.Lock]
		return fmt.Sprintf("%s is still running after %d seconds. %s Let it finish, then run %s again.", what, p.Lock.Seconds, completed, command)
	case errors.As(err, &stale):
		return fmt.Sprintf("This machine changed after you agreed, and it now also needs %s. %s Run %s again to see the changes.", Requirements(p, stale.Added), completed, command)
	case errors.As(err, &refused):
		return Refusal(p, refused.Decision, completed, command)
	case errors.As(err, &candidate):
		offered := "no " + candidate.Package
		if candidate.Version != "" {
			offered = candidate.Package + " " + candidate.Version
		}
		if !candidate.Archive && candidate.Version != "" {
			offered += " from outside Ubuntu's archive"
		}
		return fmt.Sprintf("Ubuntu's package lists offer %s, and CYFR needs Docker %d or later from Ubuntu's archive. %s Update the system's package sources, then run %s again.", offered, p.Docker.MinimumMajor, completed, command)
	case errors.As(err, &step):
		switch step.Action.Kind {
		case AptUpdate:
			return fmt.Sprintf("CYFR could not download Ubuntu's package lists. %s Check the connection, then run %s again.", completed, command)
		case AptInstall:
			return fmt.Sprintf("CYFR could not finish installing %s. %s Check the connection, or finish the package repair with `sudo dpkg --configure -a`, then run %s again.", joinAnd(step.Action.Packages), completed, command)
		case DpkgConfigure:
			return fmt.Sprintf("CYFR could not finish the interrupted package installation. %s Finish it with `sudo dpkg --configure -a`, then run %s again.", completed, command)
		default:
			return fmt.Sprintf("CYFR could not finish `%s` (%v). %s Run %s again once it can.", step.Action.Command(p).Display(), step.Err, completed, command)
		}
	case errors.Is(err, ErrInvalidPlan):
		return fmt.Sprintf("CYFR's installer refused the changes (%v). %s Run %s again.", err, completed, command)
	}
	return fmt.Sprintf("CYFR could not finish installing its requirements (%v). %s Run %s again.", err, completed, command)
}
