// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package access

import (
	"context"
	"encoding/json"
	"net"
	"slices"
	"strings"
)

// labelNetwork is on every network compose makes.
const labelNetwork = "com.docker.compose.network"

// heldBy answers, for a start of c that failed, that this computer already
// holds another CYFR's stack, running or stopped, or "" when Docker shows
// none. The compose file fixes some of its networks' subnets (and its
// container names), so one computer holds one CYFR, and cyfr down keeps
// those networks (doStop). Only a CYFR's stack has every one of them: a
// project is taken for one only where Docker holds, under that project,
// each network c fixes a subnet for, by the same compose name and on the
// same subnets. A network that merely holds an address range c fixes is
// no CYFR, and the start keeps its own sentence. Docker is asked; its
// error's words are never read, and any call that fails answers "".
func (e *Engine) heldBy(ctx context.Context, c config) string {
	fixed := map[string][]string{}
	for name, n := range c.Networks {
		for _, p := range n.Ipam.Config {
			if _, s, err := net.ParseCIDR(p.Subnet); err == nil {
				fixed[name] = append(fixed[name], s.String())
			}
		}
	}
	if len(fixed) == 0 {
		return ""
	}
	res, err := e.docker.Run(ctx, Call{Args: []string{"network", "ls", "-q", "--filter", "label=" + labelNetwork}, Deadline: probeDeadline})
	ids := strings.Fields(string(res.Stdout))
	if err != nil || len(ids) == 0 {
		return ""
	}
	res, err = e.docker.Run(ctx, Call{Args: append([]string{"network", "inspect", "--format", "{{json .}}"}, ids...), Deadline: probeDeadline})
	if err != nil {
		return ""
	}
	// Each other project's networks by compose name, with their subnets.
	held := map[string]map[string][]string{}
	for _, line := range strings.Split(string(res.Stdout), "\n") {
		var n struct {
			Labels map[string]string
			IPAM   struct{ Config []struct{ Subnet string } }
		}
		if json.Unmarshal([]byte(line), &n) != nil {
			continue
		}
		project, name := n.Labels[labelProject], n.Labels[labelNetwork]
		if project == "" || project == e.project || name == "" {
			continue
		}
		if held[project] == nil {
			held[project] = map[string][]string{}
		}
		for _, p := range n.IPAM.Config {
			if _, s, err := net.ParseCIDR(p.Subnet); err == nil {
				held[project][name] = append(held[project][name], s.String())
			}
		}
	}
	var other []string
	for project, networks := range held {
		cyfr := true
		for name, subnets := range fixed {
			for _, s := range subnets {
				cyfr = cyfr && slices.Contains(networks[name], s)
			}
		}
		if cyfr {
			other = append(other, project)
		}
	}
	if len(other) == 0 {
		return ""
	}
	slices.Sort(other)
	where := "the Compose project " + other[0]
	res, err = e.docker.Run(ctx, Call{Args: []string{"ps", "-a", "--no-trunc", "--filter", "label=" + labelProject + "=" + other[0],
		"--format", `{{.Label "` + labelWorkingDir + `"}}`}, Deadline: probeDeadline})
	if dir, _, _ := strings.Cut(strings.TrimSpace(string(res.Stdout)), "\n"); err == nil && dir != "" {
		where = "in " + dir
	}
	return "this computer already has a CYFR, " + where + ", and one computer holds one CYFR"
}
