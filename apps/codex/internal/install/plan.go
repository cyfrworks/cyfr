// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package install

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"path/filepath"
	"slices"
	"strings"
)

// PlanVersion is the version of the plan the root entry reads.
const PlanVersion = 1

// Plan is what the person agreed to, sent to the root entry on its
// standard input: the actions, the account they are for, and the init
// run that continues afterwards in a process carrying the docker group.
type Plan struct {
	Version  int           `json:"version"`
	Account  string        `json:"account"`
	UID      int           `json:"uid"`
	Actions  []Action      `json:"actions"`
	Continue *Continuation `json:"continue,omitempty"`
}

// Continuation is the cyfr init run the root entry starts as the account
// once the actions are applied: its directory, its arguments after
// `init`, and whether it reads the terminal.
type Continuation struct {
	Dir      string   `json:"dir"`
	Args     []string `json:"args"`
	Terminal bool     `json:"terminal"`
}

// ErrInvalidPlan is a plan the root entry refuses before doing anything.
var ErrInvalidPlan = errors.New("the requested changes are not ones CYFR's installer makes")

// maxPlanBytes bounds the plan the root entry reads.
const maxPlanBytes = 64 << 10

// ReadPlan reads one plan from r and validates it against the policy, the
// account sudo names as the caller (uid, name) and the init flags a
// continuation may carry. Nothing in a valid plan names a command, a
// path outside the policy or a package outside it.
func ReadPlan(r io.Reader, p Policy, callerUID int, callerName string, initFlags func(string) bool) (Plan, error) {
	var plan Plan
	dec := json.NewDecoder(io.LimitReader(r, maxPlanBytes))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&plan); err != nil {
		return Plan{}, fmt.Errorf("%w: %v", ErrInvalidPlan, err)
	}
	invalid := func(format string, args ...any) (Plan, error) {
		return Plan{}, fmt.Errorf("%w: %s", ErrInvalidPlan, fmt.Sprintf(format, args...))
	}
	if plan.Version != PlanVersion {
		return invalid("plan version %d", plan.Version)
	}
	if plan.UID != callerUID || plan.Account != callerName || !validAccount(plan.Account) {
		return invalid("the plan is for %q (%d), and sudo ran it for %q (%d)", plan.Account, plan.UID, callerName, callerUID)
	}
	if len(plan.Actions) == 0 {
		return invalid("no actions")
	}
	seen := map[Kind]bool{}
	for _, a := range plan.Actions {
		if seen[a.Kind] {
			return invalid("%s twice", a.Kind)
		}
		seen[a.Kind] = true
		switch a.Kind {
		case AptUpdate, DpkgConfigure, DockerEnable:
			if len(a.Packages) > 0 || a.Account != "" {
				return invalid("%s takes nothing", a.Kind)
			}
		case AptInstall:
			if len(a.Packages) == 0 || a.Account != "" {
				return invalid("apt-install takes packages")
			}
			for _, pkg := range a.Packages {
				if known, _ := p.dockerPackage(pkg); !known {
					return invalid("package %q", pkg)
				}
			}
			if !seen[AptUpdate] {
				return invalid("apt-install without apt-update before it")
			}
		case GroupAdd:
			if a.Account != plan.Account || len(a.Packages) > 0 {
				return invalid("group-add for %q", a.Account)
			}
			if plan.UID == 0 {
				return invalid("group-add for root")
			}
		default:
			return invalid("action %q", a.Kind)
		}
	}
	if c := plan.Continue; c != nil {
		if plan.UID == 0 {
			return invalid("a continuation for root")
		}
		if !filepath.IsAbs(c.Dir) || filepath.Clean(c.Dir) != c.Dir {
			return invalid("continuation directory %q", c.Dir)
		}
		for _, arg := range c.Args {
			if strings.ContainsRune(arg, 0) {
				return invalid("a continuation argument holds NUL")
			}
			name, _, _ := strings.Cut(arg, "=")
			if !strings.HasPrefix(name, "--") || !initFlags(strings.TrimPrefix(name, "--")) {
				return invalid("continuation argument %q", arg)
			}
		}
	}
	return plan, nil
}

// validAccount is a POSIX portable user name, as useradd accepts it.
func validAccount(name string) bool {
	if name == "" || len(name) > 32 || name[0] == '-' {
		return false
	}
	return !slices.ContainsFunc([]rune(name), func(r rune) bool {
		return !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '_' || r == '-' || r == '.')
	})
}
