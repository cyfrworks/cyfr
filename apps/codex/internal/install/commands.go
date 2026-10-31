// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package install

import (
	"encoding/json"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// Command is one action's exact call: the program by its absolute path,
// its arguments and the bound on how long it may run. The preview shows
// it and the root entry runs it, so the two never differ. A Quiet
// command's output is read, not shown.
type Command struct {
	Argv    []string
	Timeout time.Duration
	Quiet   bool
}

// Command answers the call a performs on this policy's machine.
func (a Action) Command(p Policy) Command {
	lock := "DPkg::Lock::Timeout=" + strconv.Itoa(p.Lock.Seconds)
	switch a.Kind {
	case AptUpdate:
		return Command{Argv: []string{"/usr/bin/apt-get", "update"}, Timeout: 10 * time.Minute}
	case DpkgConfigure:
		return Command{Argv: []string{"/usr/bin/dpkg", "--configure", "-a"}, Timeout: 30 * time.Minute}
	case AptInstall:
		return Command{Argv: append([]string{"/usr/bin/apt-get", "-o", lock, "install", "-y", "--no-install-recommends"}, a.Packages...), Timeout: 30 * time.Minute}
	case DockerEnable:
		return Command{Argv: []string{"/usr/bin/systemctl", "enable", "--now", p.Docker.Service}, Timeout: 2 * time.Minute}
	case GroupAdd:
		return Command{Argv: []string{"/usr/sbin/usermod", "-aG", p.Docker.Group, a.Account}, Timeout: time.Minute}
	}
	return Command{}
}

// Display is the call as the preview shows it: the program by name.
func (c Command) Display() string {
	words := append([]string{filepath.Base(c.Argv[0])}, c.Argv[1:]...)
	return strings.Join(words, " ")
}

// RootEnv is the whole environment of a root action: a fixed PATH, the
// C locale whose messages the lock checks read, and apt's front end that
// asks nothing, since the person agreed before any of it ran.
var RootEnv = []string{"PATH=/usr/sbin:/usr/bin:/sbin:/bin", "LC_ALL=C", "DEBIAN_FRONTEND=noninteractive"}

// The messages apt and dpkg print when another process holds their
// locks, read in the C locale.
const (
	listsLockMessage = "/var/lib/apt/lists/lock"
	dpkgLockMessage  = "/var/lib/dpkg/lock"
)

// parseDpkgStatus reads `dpkg-query -W -f '${Package}\t${db:Status-Status}\n'`:
// each package dpkg knows and its status.
func parseDpkgStatus(out string) map[string]string {
	status := map[string]string{}
	for _, line := range strings.Split(out, "\n") {
		if name, state, ok := strings.Cut(line, "\t"); ok && name != "" && state != "" && state != "not-installed" && state != "config-files" {
			status[name] = state
		}
	}
	return status
}

// dockerInfo is what `docker info --format '{{json .}}'` answers that the
// decision reads.
type dockerInfo struct {
	ServerVersion   string
	CgroupVersion   string
	SecurityOptions []string
}

// parseDockerInfo reads docker info's JSON into the daemon's major
// version, cgroup version and security option names (name=apparmor reads
// as apparmor).
func parseDockerInfo(out string) (major int, cgroup string, security []string, ok bool) {
	var info dockerInfo
	if err := json.Unmarshal([]byte(out), &info); err != nil || info.ServerVersion == "" {
		return 0, "", nil, false
	}
	major, _ = strconv.Atoi(strings.SplitN(info.ServerVersion, ".", 2)[0])
	for _, opt := range info.SecurityOptions {
		for _, field := range strings.Split(opt, ",") {
			if name, ok := strings.CutPrefix(field, "name="); ok {
				security = append(security, name)
			}
		}
	}
	return major, info.CgroupVersion, security, true
}

// composeV2 reports whether `docker compose version --short` answered a
// version 2 or later.
func composeV2(out string) bool {
	major, err := strconv.Atoi(strings.SplitN(strings.TrimPrefix(strings.TrimSpace(out), "v"), ".", 2)[0])
	return err == nil && major >= 2
}

// parseCandidate reads `apt-cache policy <package>`: the candidate
// version, and whether a source of the candidate is the release's own
// archive suite (<codename>, -updates or -security) in main or universe.
// Its version table holds version lines, "*** 29.1.3-0ubuntu1 500" or
// "28.2.2-0ubuntu1 500", each followed by its sources, "500
// http://archive.ubuntu.com/ubuntu resolute-updates/universe amd64
// Packages" or "100 /var/lib/dpkg/status".
func parseCandidate(out, codename string) (version string, archive bool) {
	current := ""
	for _, line := range strings.Split(out, "\n") {
		fields := strings.Fields(line)
		if len(fields) == 2 && fields[0] == "Candidate:" {
			version = fields[1]
			continue
		}
		if len(fields) > 0 && fields[0] == "***" {
			fields = fields[1:]
		}
		switch {
		case len(fields) == 2 && isNumber(fields[1]) && !isNumber(fields[0]):
			current = fields[0]
		case len(fields) >= 3 && isNumber(fields[0]) && current != "" && current == version:
			suite, component, _ := strings.Cut(fields[2], "/")
			if (suite == codename || suite == codename+"-updates" || suite == codename+"-security") && (component == "main" || component == "universe") {
				archive = true
			}
		}
	}
	if version == "(none)" {
		version = ""
	}
	return version, archive && version != ""
}

func isNumber(s string) bool {
	_, err := strconv.Atoi(s)
	return err == nil
}

// debianMajor is a Debian version's upstream major: 29 of
// "29.1.3-0ubuntu1~26.04.1" or of "1:29.0.0".
func debianMajor(version string) int {
	if _, rest, ok := strings.Cut(version, ":"); ok {
		version = rest
	}
	major, _ := strconv.Atoi(strings.SplitN(version, ".", 2)[0])
	return major
}
