// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package install

import (
	"errors"
	"fmt"
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
	if len(partly) > 0 {
		done = append(done, "left "+joinAnd(partly)+" partly installed")
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
