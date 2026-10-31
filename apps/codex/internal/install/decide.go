// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package install

import (
	"fmt"
	"slices"
)

// Outcome is what cyfr init does about the machine's requirements.
type Outcome string

const (
	// Other is a system automatic preparation does not support: init
	// prepares the project as it always has and installs nothing.
	Other Outcome = "other"
	// Satisfied is a machine that has every requirement: nothing is shown,
	// asked or run as root.
	Satisfied Outcome = "satisfied"
	// Install is a machine missing requirements the root entry installs.
	Install Outcome = "install"
	// Refuse is a requirement CYFR does not install; Decision.Cause names
	// it.
	Refuse Outcome = "refuse"
)

// Cause is why a decision refuses.
type Cause string

const (
	// CauseUniverse is a package from universe while apt's sources do not
	// enable it. Nothing edits apt's sources.
	CauseUniverse Cause = "universe"
	// CauseProvider is another provider's Docker that does not meet a
	// requirement. It is never replaced.
	CauseProvider Cause = "provider"
	// CauseContext is a Docker context naming a remote or rootless daemon,
	// which is never changed.
	CauseContext Cause = "context"
	// CauseSecurity is a kernel or daemon security requirement unmet:
	// unprivileged user namespaces, cgroup v2 or Docker's AppArmor
	// profile. No boot setting or security policy is changed.
	CauseSecurity Cause = "security"
	// CauseRefresh is an account the docker group lists while this
	// process started without the group: a new login or `newgrp docker`
	// gives it.
	CauseRefresh Cause = "refresh"
)

// Kind is one action the root entry performs. Kinds are the whole set:
// the root entry refuses any other.
type Kind string

const (
	AptUpdate     Kind = "apt-update"
	DpkgConfigure Kind = "dpkg-configure"
	AptInstall    Kind = "apt-install"
	DockerEnable  Kind = "docker-enable"
	GroupAdd      Kind = "group-add"
)

// Action is one root action: the packages of an AptInstall, the account
// of a GroupAdd.
type Action struct {
	Kind     Kind     `json:"kind"`
	Packages []string `json:"packages,omitempty"`
	Account  string   `json:"account,omitempty"`
}

// Decision is what Decide answers.
type Decision struct {
	Outcome Outcome  `json:"outcome"`
	Actions []Action `json:"actions,omitempty"`
	Cause   Cause    `json:"cause,omitempty"`
	// Detail names the unmet requirement of a refusal: the check that
	// failed, or the packages universe would supply.
	Detail string `json:"detail,omitempty"`
	// Continue is whether, once the actions are applied, init goes on in
	// a process of the account's that carries the docker group, since
	// this one does not.
	Continue bool `json:"continue,omitempty"`
}

// Decide is the decision table: what the machine's facts require, in the
// order the facts are judged. Each rule reads observed state alone, so a
// machine that already meets a requirement gets no action for it, and a
// run that stopped halfway is finished by the next one.
func Decide(p Policy, f Facts) Decision {
	if !f.Supported {
		return Decision{Outcome: Other}
	}
	refuse := func(c Cause, format string, args ...any) Decision {
		return Decision{Outcome: Refuse, Cause: c, Detail: fmt.Sprintf(format, args...)}
	}

	// The kernel's own requirements no package supplies.
	if !f.Kernel.UserNS {
		return refuse(CauseSecurity, "unprivileged user namespaces are not allowed")
	}
	if !f.Kernel.Cgroup2 {
		return refuse(CauseSecurity, "/sys/fs/cgroup is not cgroup v2")
	}

	d := f.Docker
	if d.CLI != "" {
		if d.Endpoint != "" && d.Endpoint != p.Docker.Endpoint {
			return refuse(CauseContext, "the Docker context uses %s, not this machine's daemon at %s", d.Endpoint, p.Docker.Endpoint)
		}
		if slices.Contains(d.Security, "rootless") {
			return refuse(CauseContext, "the Docker daemon runs rootless")
		}
	}

	var actions []Action
	if f.Interrupted {
		actions = append(actions, Action{Kind: DpkgConfigure})
	}

	var missing []string
	enable := false
	switch {
	case d.CLI == "other":
		switch d.Daemon {
		case "running":
			if d.Major < p.Docker.MinimumMajor {
				return refuse(CauseProvider, "Docker Engine %d is installed, and CYFR needs %d or later", d.Major, p.Docker.MinimumMajor)
			}
			if !d.Compose {
				return refuse(CauseProvider, "Docker Compose v2 does not answer")
			}
		case "stopped":
			if d.Service == "absent" {
				return refuse(CauseProvider, "the Docker daemon is not running")
			}
			enable = true
		}
	default:
		for _, pkg := range p.Docker.Packages {
			if !f.installed(pkg.Package) {
				missing = append(missing, pkg.Package)
			}
		}
		if d.Daemon == "running" && d.Major < p.Docker.MinimumMajor && !slices.Contains(missing, "docker.io") {
			// apt-get install upgrades an installed package to its
			// candidate, which the root entry checks is adequate first.
			missing = append([]string{"docker.io"}, missing...)
		}
		if d.Daemon == "running" && !d.Compose && f.installed("docker-compose-v2") {
			return refuse(CauseProvider, "docker-compose-v2 is installed and `docker compose` does not answer")
		}
		enable = d.Service != "active" || !d.Enabled
	}

	if len(missing) > 0 {
		var fromUniverse []string
		for _, name := range missing {
			if _, universe := p.dockerPackage(name); universe {
				fromUniverse = append(fromUniverse, name)
			}
		}
		if len(fromUniverse) > 0 && !f.Universe {
			return refuse(CauseUniverse, "%s", joinAnd(fromUniverse))
		}
		actions = append(actions, Action{Kind: AptUpdate}, Action{Kind: AptInstall, Packages: missing})
	}
	if enable {
		actions = append(actions, Action{Kind: DockerEnable})
	}

	// A running daemon this account can read is checked now; one it cannot
	// read yet, or one about to be installed, is checked by the run that
	// follows the actions.
	if d.Daemon == "running" && len(missing) == 0 {
		if d.Cgroup != "2" {
			return refuse(CauseSecurity, "the Docker daemon does not use cgroup v2")
		}
		if !slices.Contains(d.Security, "apparmor") {
			return refuse(CauseSecurity, "the Docker daemon does not apply its AppArmor profile")
		}
	}

	cont := false
	if !f.Account.Root {
		switch {
		case !f.Account.Member:
			actions = append(actions, Action{Kind: GroupAdd, Account: f.Account.Name})
			cont = true
		case !f.Account.Process && len(actions) > 0:
			cont = true
		case !f.Account.Process:
			return refuse(CauseRefresh, "this terminal started before %s joined the %s group", f.Account.Name, p.Docker.Group)
		}
	}

	if len(actions) == 0 {
		return Decision{Outcome: Satisfied}
	}
	return Decision{Outcome: Install, Actions: actions, Continue: cont}
}

// joinAnd joins names as a sentence lists them: "a", "a and b",
// "a, b and c".
func joinAnd(names []string) string {
	switch len(names) {
	case 0:
		return ""
	case 1:
		return names[0]
	}
	out := names[0]
	for _, n := range names[1 : len(names)-1] {
		out += ", " + n
	}
	return out + " and " + names[len(names)-1]
}
