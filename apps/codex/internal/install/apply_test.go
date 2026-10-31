// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package install_test

import (
	"context"
	"errors"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/cyfr/codex/internal/install"
	"github.com/cyfr/codex/internal/install/fake"
)

var alice = install.Account{Name: "alice", UID: 1000}

type noProgress struct{}

func (noProgress) Start(install.Action) {}
func (noProgress) Done(install.Action)  {}

// agree is what cyfr init sends the root entry for m as alice sees it now.
func agree(t *testing.T, p install.Policy, m *fake.Machine) install.Plan {
	t.Helper()
	d := install.Decide(p, m.Facts(alice, false))
	if d.Outcome != install.Install {
		t.Fatalf("the machine needs nothing to agree to: %+v", d)
	}
	return install.Plan{Version: install.PlanVersion, Account: alice.Name, UID: alice.UID, Actions: d.Actions}
}

// TestApplyConvergesAndARerunDoesNothing installs Docker on a fresh
// machine, then shows the account's next observation is satisfied and a
// second run of the same plan makes no apt or dpkg transaction.
func TestApplyConvergesAndARerunDoesNothing(t *testing.T) {
	p := install.Load()
	m := fake.New(p)
	plan := agree(t, p, m)
	if err := install.Apply(context.Background(), p, m.Host(), plan, noProgress{}); err != nil {
		t.Fatal(err)
	}
	if !slices.Contains(m.Members, "alice") || m.Packages["docker.io"] != "installed" || m.Packages["docker-compose-v2"] != "installed" || m.Service != "active" || !m.Enabled {
		t.Fatalf("the machine after the install: %+v", m)
	}
	if d := install.Decide(p, m.Facts(alice, true)); d.Outcome != install.Satisfied {
		t.Fatalf("a process carrying the group still needs %+v", d)
	}
	first := len(m.Ran)
	if err := install.Apply(context.Background(), p, m.Host(), plan, noProgress{}); err != nil {
		t.Fatal(err)
	}
	if len(m.Ran) != first {
		t.Fatalf("the rerun ran %v", m.Ran[first:])
	}
}

// TestApplyFinishesWhatAnInterruptedRunLeft stops the run before each of
// its commands in turn, then runs init's decision and the install again
// from what the machine shows, and the machine converges with one group
// entry and every package installed.
func TestApplyFinishesWhatAnInterruptedRunLeft(t *testing.T) {
	p := install.Load()
	steps := len(agree(t, p, fake.New(p)).Actions) + 1 // apt-cache policy runs before the install
	for at := 1; at <= steps; at++ {
		m := fake.New(p)
		m.FailAt = at
		if err := install.Apply(context.Background(), p, m.Host(), agree(t, p, m), noProgress{}); err == nil {
			t.Fatalf("failing command %d ended in success", at)
		}
		m.FailAt = 0
		if err := install.Apply(context.Background(), p, m.Host(), agree(t, p, m), noProgress{}); err != nil {
			t.Fatalf("the retry after failing command %d: %v", at, err)
		}
		if d := install.Decide(p, m.Facts(alice, true)); d.Outcome != install.Satisfied || len(m.Members) != 1 {
			t.Fatalf("after failing command %d and a retry: %+v, members %v", at, d, m.Members)
		}
	}

	// dpkg killed while unpacking: the retry repairs it first.
	m := fake.New(p)
	m.InterruptInstall = true
	if err := install.Apply(context.Background(), p, m.Host(), agree(t, p, m), noProgress{}); err == nil {
		t.Fatal("the interrupted install ended in success")
	}
	plan := agree(t, p, m)
	if plan.Actions[0].Kind != install.DpkgConfigure {
		t.Fatalf("the retry after an interrupted dpkg starts with %+v", plan.Actions)
	}
	if err := install.Apply(context.Background(), p, m.Host(), plan, noProgress{}); err != nil {
		t.Fatal(err)
	}
	if d := install.Decide(p, m.Facts(alice, true)); d.Outcome != install.Satisfied {
		t.Fatalf("after repairing dpkg: %+v", d)
	}
}

// TestEachLockRefusesAtItsOwnDeadline holds each of the three locks in
// turn: each ends the run as that lock's own error, after its own
// deadline, without the lock taken from its holder or anything installed.
func TestEachLockRefusesAtItsOwnDeadline(t *testing.T) {
	p := install.Load()
	for _, c := range []struct {
		lock install.Lock
		hold func(*fake.Machine)
	}{
		{install.LockInstall, func(m *fake.Machine) { m.HeldInstall = true }},
		{install.LockLists, func(m *fake.Machine) { m.HeldLists = true }},
		{install.LockDpkg, func(m *fake.Machine) { m.HeldDpkg = true }},
	} {
		t.Run(string(c.lock), func(t *testing.T) {
			m := fake.New(p)
			plan := agree(t, p, m)
			c.hold(m)
			start := m.Host().Now()
			err := install.Apply(context.Background(), p, m.Host(), plan, noProgress{})
			var lock install.LockError
			if !errors.As(err, &lock) || lock.Lock != c.lock {
				t.Fatalf("Apply = %v, want the %s lock's error", err, c.lock)
			}
			// The install and list locks are waited for here; dpkg's by
			// apt's own DPkg::Lock::Timeout, which the command carries.
			waited := m.Host().Now().Sub(start)
			if c.lock != install.LockDpkg && (waited < p.LockWait() || waited > p.LockWait()+5*time.Second) {
				t.Errorf("waited %s for the %s lock, want its %s deadline", waited, c.lock, p.LockWait())
			}
			if c.lock == install.LockDpkg && !slices.ContainsFunc(m.Ran, func(argv []string) bool {
				return slices.Contains(argv, "DPkg::Lock::Timeout=60")
			}) {
				t.Errorf("no install carried dpkg's lock deadline: %v", m.Ran)
			}
			if !(m.HeldInstall || m.HeldLists || m.HeldDpkg) || m.Packages["docker.io"] == "installed" {
				t.Errorf("after the %s lock: %+v", c.lock, m)
			}
		})
	}
}

// TestApplyRefusesWhatWasNotAgreed changes the machine between the
// agreement and the root entry's own observation: a newly needed package
// stops the run before any command, and an action no longer needed is
// skipped.
func TestApplyRefusesWhatWasNotAgreed(t *testing.T) {
	p := install.Load()
	m := fake.New(p)
	plan := agree(t, p, m)
	delete(m.Packages, "apparmor")
	err := install.Apply(context.Background(), p, m.Host(), plan, noProgress{})
	var stale install.StaleError
	if !errors.As(err, &stale) || len(m.Ran) != 0 {
		t.Fatalf("Apply = %v after running %v, want a stale refusal before any command", err, m.Ran)
	}
	if got := install.Requirements(p, stale.Added); got != "apparmor" {
		t.Errorf("the refusal adds %q", got)
	}

	m = fake.New(p)
	plan = agree(t, p, m)
	m.Members = []string{"alice"}
	if err := install.Apply(context.Background(), p, m.Host(), plan, noProgress{}); err != nil {
		t.Fatal(err)
	}
	if slices.ContainsFunc(m.Ran, func(argv []string) bool { return argv[0] == "/usr/sbin/usermod" }) {
		t.Errorf("an account already in the group was added again: %v", m.Ran)
	}
}

// TestApplyRefusesAnInadequateCandidate installs no Docker whose candidate
// is older than the policy's minimum or comes from outside the release's
// archive.
func TestApplyRefusesAnInadequateCandidate(t *testing.T) {
	p := install.Load()
	for name, set := range map[string]func(*fake.Machine){
		"too old":      func(m *fake.Machine) { m.Candidate = "27.5.1-0ubuntu3" },
		"another repo": func(m *fake.Machine) { m.CandidateSuite = "stable/main" },
	} {
		t.Run(name, func(t *testing.T) {
			m := fake.New(p)
			set(m)
			err := install.Apply(context.Background(), p, m.Host(), agree(t, p, m), noProgress{})
			var candidate install.CandidateError
			if !errors.As(err, &candidate) || m.Packages["docker.io"] != "" {
				t.Fatalf("Apply = %v, docker.io %q", err, m.Packages["docker.io"])
			}
			if s := install.Failure(p, err, "Nothing was installed.", "`cyfr init`"); !strings.Contains(s, "docker.io") {
				t.Errorf("the refusal does not name the candidate: %s", s)
			}
		})
	}
}

// TestApplyRefusesASecurityRequirementRootSees finds, as root can read
// the daemon, a Docker without its AppArmor profile, which no action
// fixes.
func TestApplyRefusesASecurityRequirementRootSees(t *testing.T) {
	p := install.Load()
	m := fake.New(p)
	m.Packages = map[string]string{"docker.io": "installed", "docker-compose-v2": "installed", "apparmor": "installed"}
	m.Service, m.Enabled = "active", true
	m.Security = []string{"seccomp"}
	plan := agree(t, p, m) // alice sees a daemon she may not read, and joins the group
	err := install.Apply(context.Background(), p, m.Host(), plan, noProgress{})
	var refused install.RefusedError
	if !errors.As(err, &refused) || refused.Decision.Cause != install.CauseSecurity || len(m.Ran) != 0 {
		t.Fatalf("Apply = %v, ran %v", err, m.Ran)
	}
}

// TestCompletedSaysWhatChanged renders what changed between two
// observations, and "nothing" only when nothing did.
func TestCompletedSaysWhatChanged(t *testing.T) {
	p := install.Load()
	m := fake.New(p)
	before := m.Facts(alice, false)
	if got := install.Completed(p, before, before); got != "Nothing was installed." {
		t.Errorf("unchanged: %q", got)
	}
	m.HeldDpkg = true
	_ = install.Apply(context.Background(), p, m.Host(), agree(t, p, m), noProgress{})
	if got := install.Completed(p, before, m.Facts(alice, false)); got != "Nothing was installed." {
		t.Errorf("after a refused install: %q", got)
	}
	m.HeldDpkg = false
	interrupted := fake.New(p)
	interrupted.InterruptInstall = true
	_ = install.Apply(context.Background(), p, interrupted.Host(), agree(t, p, interrupted), noProgress{})
	if got, want := install.Completed(p, before, interrupted.Facts(alice, false)), "CYFR left docker.io partly installed."; got != want {
		t.Errorf("after an interrupted install:\n got %q\nwant %q", got, want)
	}
	// An interrupt that leaves only a dependency unfinished changed the
	// machine all the same.
	if got, want := install.Completed(p, install.Facts{}, install.Facts{Interrupted: true}), "CYFR left a package installation unfinished."; got != want {
		t.Errorf("after an interrupt that left a dependency unfinished:\n got %q\nwant %q", got, want)
	}
	if err := install.Apply(context.Background(), p, m.Host(), agree(t, p, m), noProgress{}); err != nil {
		t.Fatal(err)
	}
	want := "CYFR installed docker.io and docker-compose-v2, started the Docker service and added alice to the docker group."
	if got := install.Completed(p, before, m.Facts(alice, false)); got != want {
		t.Errorf("after the install:\n got %q\nwant %q", got, want)
	}
}
