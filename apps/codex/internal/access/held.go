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
// none. The compose file fixes its networks' subnets (and its container
// names), so one computer holds one CYFR: a network of another compose
// project on a subnet c fixes is that CYFR's, which cyfr down keeps
// (doStop). Docker is asked what holds the subnets; its error's words are
// never read, and any call that fails answers "".
func (e *Engine) heldBy(ctx context.Context, c config) string {
	var fixed []*net.IPNet
	for _, n := range c.Networks {
		for _, p := range n.Ipam.Config {
			if _, s, err := net.ParseCIDR(p.Subnet); err == nil {
				fixed = append(fixed, s)
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
	var other []string
	for _, line := range strings.Split(string(res.Stdout), "\n") {
		var n struct {
			Labels map[string]string
			IPAM   struct{ Config []struct{ Subnet string } }
		}
		if json.Unmarshal([]byte(line), &n) != nil {
			continue
		}
		project := n.Labels[labelProject]
		if project == "" || project == e.project || slices.Contains(other, project) {
			continue
		}
		if slices.ContainsFunc(n.IPAM.Config, func(p struct{ Subnet string }) bool {
			_, s, err := net.ParseCIDR(p.Subnet)
			return err == nil && slices.ContainsFunc(fixed, func(f *net.IPNet) bool { return f.Contains(s.IP) || s.Contains(f.IP) })
		}) {
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
