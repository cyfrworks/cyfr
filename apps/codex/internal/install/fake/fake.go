// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package fake is a package manager and system for install's tests: an
// Ubuntu 26.04 machine whose dpkg database, Docker service, docker group
// and locks are fields, changed by the same commands the root entry
// runs on a real one.
package fake

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/cyfr/codex/internal/install"
)

// Machine is the fake system. Its zero value is not usable; New makes a
// fresh Ubuntu 26.04 machine with no Docker.
type Machine struct {
	mu sync.Mutex

	Policy   install.Policy
	Universe bool
	// Packages is dpkg's database: name to status.
	Packages map[string]string
	// Members is the docker group's member list in /etc/group.
	Members []string
	// Service and Enabled are docker.service's state.
	Service string
	Enabled bool
	// Other is another provider's Docker on PATH instead of Ubuntu's.
	Other bool
	// Major, Cgroup and Security are the daemon's.
	Major    int
	Cgroup   string
	Security []string
	// Candidate is apt-cache policy's candidate of docker.io, and
	// CandidateSuite the suite/component it comes from.
	Candidate, CandidateSuite string
	UserNS, Cgroup2           bool

	// HeldInstall, HeldLists and HeldDpkg are locks another process holds.
	HeldInstall, HeldLists, HeldDpkg bool
	// FailAt fails the FailAt'th command run (1-based) before it changes
	// anything; InterruptInstall makes apt-get install unpack its first
	// package and stop, as a killed dpkg leaves it.
	FailAt           int
	InterruptInstall bool
	// Offline fails apt-get update as an unreachable archive does.
	Offline bool

	// Ran is every command run, in order; Observed counts observations.
	Ran      [][]string
	Observed int
	// clock advances with each command, so lock deadlines pass without
	// waiting.
	clock time.Time
}

// New answers a fresh Ubuntu 26.04 machine: universe enabled, no Docker,
// apparmor installed as Ubuntu installs it.
func New(p install.Policy) *Machine {
	return &Machine{
		Policy:         p,
		Universe:       true,
		Packages:       map[string]string{"apparmor": "installed"},
		Service:        "absent",
		Major:          29,
		Cgroup:         "2",
		Security:       []string{"apparmor", "seccomp", "cgroupns"},
		Candidate:      "29.1.3-0ubuntu1~26.04.1",
		CandidateSuite: p.System.Codename + "-updates/universe",
		UserNS:         true,
		Cgroup2:        true,
		clock:          time.Date(2026, 10, 31, 0, 0, 0, 0, time.UTC),
	}
}

// Facts answers what cyfr init observes as account, a process carrying
// the docker group when process is set.
func (m *Machine) Facts(account install.Account, process bool) install.Facts {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.facts(account, process, false)
}

// facts is the machine as account sees it, or as root sees it for
// account: root reads the daemon whatever the account's groups.
func (m *Machine) facts(account install.Account, process, root bool) install.Facts {
	m.Observed++
	f := install.Facts{
		Supported:   true,
		System:      "Ubuntu 26.04.1 LTS",
		Universe:    m.Universe,
		Packages:    map[string]string{},
		Interrupted: slices.ContainsFunc(mapValues(m.Packages), func(s string) bool { return s != "installed" }),
		Kernel:      install.Kernel{UserNS: m.UserNS, Cgroup2: m.Cgroup2},
		Account:     account,
	}
	for k, v := range m.Packages {
		f.Packages[k] = v
	}
	f.Account.Member = slices.Contains(m.Members, account.Name)
	f.Account.Process = process && f.Account.Member || account.Root
	d := install.Docker{Service: m.Service, Enabled: m.Enabled}
	switch {
	case m.Other:
		d.CLI = "other"
	case m.Packages["docker.io"] == "installed":
		d.CLI = "ubuntu"
	}
	if d.CLI != "" {
		d.Endpoint = m.Policy.Docker.Endpoint
		switch {
		case m.Service != "active":
			d.Daemon = "stopped"
		case !f.Account.Process && !account.Root && !root:
			d.Daemon = "denied"
		default:
			d.Daemon, d.Major, d.Cgroup, d.Security = "running", m.Major, m.Cgroup, slices.Clone(m.Security)
		}
		d.Compose = m.Other || m.Packages["docker-compose-v2"] == "installed"
	}
	f.Docker = d
	return f
}

func mapValues(m map[string]string) []string {
	var out []string
	for _, v := range m {
		out = append(out, v)
	}
	return out
}

// Host answers the machine as the root entry's Host.
func (m *Machine) Host() install.Host { return host{m} }

type host struct{ m *Machine }

func (h host) Now() time.Time {
	h.m.mu.Lock()
	defer h.m.mu.Unlock()
	return h.m.clock
}

func (h host) Observe(_ context.Context, account install.Account) (install.Facts, error) {
	h.m.mu.Lock()
	defer h.m.mu.Unlock()
	return h.m.facts(account, false, true), nil
}

func (h host) Sleep(ctx context.Context, d time.Duration) error {
	h.m.mu.Lock()
	defer h.m.mu.Unlock()
	h.m.clock = h.m.clock.Add(d)
	return ctx.Err()
}

func (h host) Lock(ctx context.Context, path string, wait time.Duration) (func(), error) {
	m := h.m
	m.mu.Lock()
	defer m.mu.Unlock()
	if path != m.Policy.Lock.Path {
		return nil, fmt.Errorf("lock %s is not the policy's", path)
	}
	if m.HeldInstall {
		m.clock = m.clock.Add(wait)
		return nil, install.ErrLockHeld
	}
	return func() {}, nil
}

var errExit = errors.New("exit status 100")

func (h host) Run(ctx context.Context, c install.Command) (string, error) {
	m := h.m
	m.mu.Lock()
	defer m.mu.Unlock()
	m.Ran = append(m.Ran, slices.Clone(c.Argv))
	m.clock = m.clock.Add(3 * time.Second)
	if m.FailAt > 0 && len(m.Ran) == m.FailAt {
		return "E: failed before changing anything", errExit
	}
	argv := c.Argv
	switch {
	case slices.Equal(argv, []string{"/usr/bin/apt-get", "update"}):
		if m.HeldLists {
			return "E: Could not get lock /var/lib/apt/lists/lock. It is held by process 4242 (apt-get)", errExit
		}
		if m.Offline {
			return "E: Failed to fetch http://archive.ubuntu.com/ubuntu/dists/resolute/InRelease", errExit
		}
		return "Reading package lists... Done", nil
	case slices.Equal(argv, []string{"/usr/bin/apt-cache", "policy", "docker.io"}):
		return fmt.Sprintf("docker.io:\n  Installed: (none)\n  Candidate: %s\n  Version table:\n     %s 500\n        500 http://archive.ubuntu.com/ubuntu %s amd64 Packages\n", m.Candidate, m.Candidate, m.CandidateSuite), nil
	case len(argv) > 5 && argv[0] == "/usr/bin/apt-get" && slices.Contains(argv, "install"):
		if m.HeldDpkg {
			return "E: Could not get lock /var/lib/dpkg/lock-frontend. It is held by process 4243 (unattended-upgr)", errExit
		}
		pkgs := argv[slices.Index(argv, "--no-install-recommends")+1:]
		for i, pkg := range pkgs {
			if known, _ := policyPackage(m.Policy, pkg); !known {
				return "E: Unable to locate package " + pkg, errExit
			}
			if m.InterruptInstall && i == 0 {
				m.Packages[pkg] = "unpacked"
				m.InterruptInstall = false
				return "dpkg: interrupted", errExit
			}
			m.Packages[pkg] = "installed"
			if pkg == "docker.io" {
				// Ubuntu's docker.io enables and starts its service.
				m.Service, m.Enabled = "active", true
			}
		}
		return "", nil
	case slices.Equal(argv, []string{"/usr/bin/dpkg", "--configure", "-a"}):
		if m.HeldDpkg {
			return "dpkg: error: dpkg frontend lock was locked by another process with pid 4243\nNote: removing the lock file is always wrong, and can end up damaging the\nlocked area and the entire system. See <https://wiki.debian.org/Teams/Dpkg/FAQ#db-lock>.\n/var/lib/dpkg/lock-frontend", errExit
		}
		for k, v := range m.Packages {
			if v != "installed" {
				m.Packages[k] = "installed"
				if k == "docker.io" {
					m.Service, m.Enabled = "active", true
				}
			}
		}
		return "", nil
	case len(argv) == 4 && argv[0] == "/usr/bin/systemctl" && argv[1] == "enable" && argv[2] == "--now":
		if m.Service == "absent" {
			return "Failed to enable unit: Unit file docker.service does not exist.", errExit
		}
		m.Service, m.Enabled = "active", true
		return "", nil
	case len(argv) == 4 && argv[0] == "/usr/sbin/usermod" && argv[1] == "-aG" && argv[2] == m.Policy.Docker.Group:
		if !slices.Contains(m.Members, argv[3]) {
			m.Members = append(m.Members, argv[3])
		}
		return "", nil
	}
	return "", fmt.Errorf("the fake machine does not run %s", strings.Join(argv, " "))
}

func policyPackage(p install.Policy, name string) (bool, bool) {
	for _, pkg := range p.Docker.Packages {
		if pkg.Package == name {
			return true, pkg.Universe
		}
	}
	return false, false
}

// Transactions counts apt and dpkg calls that change the system:
// updates, installs and configures.
func (m *Machine) Transactions() int {
	m.mu.Lock()
	defer m.mu.Unlock()
	n := 0
	for _, argv := range m.Ran {
		if argv[0] == "/usr/bin/apt-get" || argv[0] == "/usr/bin/dpkg" {
			n++
		}
	}
	return n
}
