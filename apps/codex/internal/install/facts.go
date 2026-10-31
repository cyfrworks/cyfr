// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package install

import (
	"slices"
	"strings"
)

// System is the operating system os-release describes, with the CPU
// architecture in the release archives' naming (amd64, arm64).
type System struct {
	ID, VersionID, Codename, Name, Arch string
}

// ParseSystem reads os-release text as data, never as shell: KEY=value
// lines, the value unquoted, or quoted whole in double or single quotes.
// Name is PRETTY_NAME, else NAME and VERSION_ID, else "Linux".
func ParseSystem(osRelease, arch string) System {
	values := map[string]string{}
	for _, line := range strings.Split(osRelease, "\n") {
		line = strings.TrimSpace(line)
		key, value, ok := strings.Cut(line, "=")
		if !ok || line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if n := len(value); n >= 2 && (value[0] == '"' || value[0] == '\'') && value[n-1] == value[0] {
			value = value[1 : n-1]
		}
		values[key] = value
	}
	name := values["PRETTY_NAME"]
	if name == "" {
		name = strings.TrimSpace(values["NAME"] + " " + values["VERSION_ID"])
	}
	if name == "" {
		name = "Linux"
	}
	return System{ID: values["ID"], VersionID: values["VERSION_ID"], Codename: values["VERSION_CODENAME"], Name: name, Arch: arch}
}

// UniverseArgs is the apt-get call whose output UniverseEnabled reads: the
// index targets apt's configuration names, read without the downloaded
// lists.
var UniverseArgs = []string{"indextargets", "--no-release-info", "--format", "$(RELEASE) $(COMPONENT) $(IDENTIFIER)"}

// UniverseEnabled reports whether apt's index targets include universe's
// packages for the release codename itself; universe of the security
// suite alone, of another release or of a third-party suite is not the
// archive's universe.
func UniverseEnabled(indextargets, codename, component string) bool {
	want := codename + " " + component + " Packages"
	return slices.Contains(strings.Split(indextargets, "\n"), want)
}

// Facts are what the machine has, as cyfr init observes it.
type Facts struct {
	// Supported is whether automatic preparation runs on this system;
	// System names it in refusals.
	Supported bool   `json:"supported"`
	System    string `json:"system"`
	Universe  bool   `json:"universe"`
	// Packages is dpkg's status of each policy package it knows
	// ("installed", "unpacked", "half-configured", ...); a package dpkg
	// does not know is absent.
	Packages map[string]string `json:"packages"`
	// Interrupted is whether dpkg reports a package left unconfigured by
	// an interrupted installation (dpkg --audit).
	Interrupted bool    `json:"dpkg_interrupted"`
	Docker      Docker  `json:"docker"`
	Kernel      Kernel  `json:"kernel"`
	Account     Account `json:"account"`
}

// Docker is the Docker on this machine.
type Docker struct {
	// CLI is whose docker program PATH finds: "" none, "ubuntu" the
	// docker.io package's, "other" any other provider's.
	CLI string `json:"cli"`
	// Endpoint is the daemon the CLI's context talks to.
	Endpoint string `json:"endpoint"`
	// Daemon is "running", "denied" (the account may not use its socket)
	// or "stopped" (nothing answers).
	Daemon string `json:"daemon"`
	// Major, Cgroup and Security are the running daemon's: its major
	// version, its cgroup version and its SecurityOptions names.
	Major    int      `json:"major"`
	Cgroup   string   `json:"cgroup"`
	Security []string `json:"security"`
	// Compose is whether `docker compose` answers a v2 or later version.
	Compose bool `json:"compose"`
	// Service is the docker.service unit: "active", "inactive" or
	// "absent"; Enabled whether it starts at boot.
	Service string `json:"service"`
	Enabled bool   `json:"enabled"`
}

// Kernel is what the keeper needs of the kernel itself.
type Kernel struct {
	// UserNS is whether unprivileged user namespaces are allowed.
	UserNS bool `json:"userns"`
	// Cgroup2 is whether /sys/fs/cgroup is the unified hierarchy.
	Cgroup2 bool `json:"cgroup2"`
}

// Account is the person running cyfr init.
type Account struct {
	Name string `json:"name"`
	UID  int    `json:"uid"`
	Root bool   `json:"root"`
	// Member is whether /etc/group lists the account in the docker
	// group; Process whether this process already carries that group.
	Member  bool `json:"member"`
	Process bool `json:"process"`
}

func (f Facts) installed(pkg string) bool {
	return f.Packages[pkg] == "installed"
}
