// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package install

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"
	"time"
)

// Host is the machine as the root entry sees and changes it. The real
// one is the running system (NewHost); tests stand in a fake package
// manager.
type Host interface {
	// Observe answers the machine's facts for account, as root sees them.
	Observe(ctx context.Context, account Account) (Facts, error)
	// Run runs c with RootEnv, its output shown on the terminal unless c
	// is Quiet, and answers the output; it fails on a non-zero exit or at
	// c's timeout.
	Run(ctx context.Context, c Command) (string, error)
	// Lock takes the machine-wide install lock at path, waiting up to
	// wait for another holder, and answers its release.
	Lock(ctx context.Context, path string, wait time.Duration) (func(), error)
	// Now is the clock the lock deadlines read, and Sleep waits on it
	// until d passes or ctx ends.
	Now() time.Time
	Sleep(ctx context.Context, d time.Duration) error
}

// Lock names the lock a LockError is for.
type Lock string

const (
	LockInstall Lock = "install"
	LockLists   Lock = "lists"
	LockDpkg    Lock = "dpkg"
)

// ErrLockHeld is the error Host.Lock answers when the wait ends with the
// lock still held.
var ErrLockHeld = errors.New("lock held")

// LockError is a lock still held by another process at its deadline.
// Nothing deletes the lock or stops its holder.
type LockError struct{ Lock Lock }

func (e LockError) Error() string { return fmt.Sprintf("the %s lock is still held", e.Lock) }

// StaleError is a machine that, when the root entry observed it again,
// needed an action the person did not agree to.
type StaleError struct{ Added []Action }

func (e StaleError) Error() string { return "the machine changed after the changes were agreed" }

// RefusedError is a requirement the fresh observation found that CYFR
// does not install.
type RefusedError struct{ Decision Decision }

func (e RefusedError) Error() string { return string(e.Decision.Cause) + ": " + e.Decision.Detail }

// CandidateError is a Docker package whose candidate in apt's lists is
// absent, too old, or not from the release's own archive.
type CandidateError struct {
	Package, Version string
	Archive          bool
}

func (e CandidateError) Error() string {
	return fmt.Sprintf("the candidate of %s is %q (archive %t)", e.Package, e.Version, e.Archive)
}

// StepError is an action whose command failed.
type StepError struct {
	Action Action
	Err    error
}

func (e StepError) Error() string { return fmt.Sprintf("%s: %v", e.Action.Kind, e.Err) }
func (e StepError) Unwrap() error { return e.Err }

// Progress is told each action as it starts and as it ends.
type Progress interface {
	Start(Action)
	Done(Action)
}

// Apply performs plan on h under the install lock. It observes the
// machine again first and performs what the machine still needs: an
// action no longer needed is skipped, and one the person did not agree to
// stops Apply before anything runs. Each step reads its own deadline for
// its own lock, and none deletes a lock or stops its holder.
func Apply(ctx context.Context, p Policy, h Host, plan Plan, progress Progress) error {
	release, err := h.Lock(ctx, p.Lock.Path, p.LockWait())
	switch {
	case errors.Is(err, ErrLockHeld):
		return LockError{LockInstall}
	case err != nil:
		return err
	}
	defer release()

	facts, err := h.Observe(ctx, Account{Name: plan.Account, UID: plan.UID, Root: plan.UID == 0})
	if err != nil {
		return err
	}
	// The process carrying the group is the continuation's concern, not
	// this one's.
	facts.Account.Process = true
	fresh := Decide(p, facts)
	switch fresh.Outcome {
	case Refuse:
		return RefusedError{fresh}
	case Satisfied, Other:
		return nil
	}
	if added := unagreed(fresh.Actions, plan.Actions); len(added) > 0 {
		return StaleError{added}
	}

	for _, a := range fresh.Actions {
		if err := ctx.Err(); err != nil {
			return err
		}
		progress.Start(a)
		if err := perform(ctx, p, h, a); err != nil {
			return err
		}
		progress.Done(a)
	}
	return nil
}

// unagreed answers the actions of fresh the agreed ones do not cover: a
// kind not agreed, or an install of a package not agreed.
func unagreed(fresh, agreed []Action) []Action {
	var added []Action
	for _, a := range fresh {
		i := slices.IndexFunc(agreed, func(b Action) bool { return b.Kind == a.Kind })
		switch {
		case i < 0:
			added = append(added, a)
		case a.Kind == AptInstall:
			var extra []string
			for _, pkg := range a.Packages {
				if !slices.Contains(agreed[i].Packages, pkg) {
					extra = append(extra, pkg)
				}
			}
			if len(extra) > 0 {
				added = append(added, Action{Kind: AptInstall, Packages: extra})
			}
		case a.Kind == GroupAdd && a.Account != agreed[i].Account:
			added = append(added, a)
		}
	}
	return added
}

// perform runs one action. The list update retries only apt's refusal for
// its list lock, until that lock's deadline; dpkg's own lock is waited
// for by apt (DPkg::Lock::Timeout) and, for dpkg --configure, by retries
// to the same deadline.
func perform(ctx context.Context, p Policy, h Host, a Action) error {
	c := a.Command(p)
	switch a.Kind {
	case AptUpdate:
		return retryLocked(ctx, p, h, a, c, listsLockMessage, LockLists)
	case DpkgConfigure:
		return retryLocked(ctx, p, h, a, c, dpkgLockMessage, LockDpkg)
	case AptInstall:
		if slices.Contains(a.Packages, "docker.io") {
			if err := checkCandidate(ctx, p, h, "docker.io"); err != nil {
				return err
			}
		}
		out, err := h.Run(ctx, c)
		if err != nil && strings.Contains(out, dpkgLockMessage) {
			return LockError{LockDpkg}
		}
		if err != nil {
			return StepError{a, err}
		}
		return nil
	default:
		if _, err := h.Run(ctx, c); err != nil {
			return StepError{a, err}
		}
		return nil
	}
}

// lockRetry is how long a step waits between attempts at a held lock.
const lockRetry = 2 * time.Second

func retryLocked(ctx context.Context, p Policy, h Host, a Action, c Command, message string, lock Lock) error {
	deadline := h.Now().Add(p.LockWait())
	for {
		out, err := h.Run(ctx, c)
		switch {
		case err == nil:
			return nil
		case !strings.Contains(out, message):
			return StepError{a, err}
		case !h.Now().Before(deadline):
			return LockError{lock}
		}
		if err := h.Sleep(ctx, lockRetry); err != nil {
			return err
		}
	}
}

// checkCandidate refuses a Docker package whose candidate is absent, older
// than the policy's minimum or not from the release's own archive, before
// apt installs it.
func checkCandidate(ctx context.Context, p Policy, h Host, pkg string) error {
	out, err := h.Run(ctx, Command{Argv: []string{"/usr/bin/apt-cache", "policy", pkg}, Timeout: time.Minute, Quiet: true})
	if err != nil {
		return StepError{Action{Kind: AptInstall, Packages: []string{pkg}}, err}
	}
	version, archive := parseCandidate(out, p.System.Codename)
	if version == "" || !archive || debianMajor(version) < p.Docker.MinimumMajor {
		return CandidateError{Package: pkg, Version: version, Archive: archive}
	}
	return nil
}
