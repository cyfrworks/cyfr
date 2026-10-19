// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package reach

import (
	"context"
	"encoding/json"
	"fmt"
	"slices"
	"strings"
	"time"
)

// The labels the engine reads containers by: compose's own, and the ones
// it puts on a join container, which compose does not start.
const (
	labelProject      = "com.docker.compose.project"
	labelService      = "com.docker.compose.service"
	labelJoinProject  = "com.cyfr.reach.project"
	labelJoinID       = "com.cyfr.reach.join-id"
	labelJoinDeadline = "com.cyfr.reach.join-deadline"
)

// probeDeadline bounds one read of docker's state: a ps, an inspect or a
// status.
const probeDeadline = 30 * time.Second

// The formats ps reads containers in, one JSON object a line.
const (
	psFormat     = `{"name":{{json .Names}},"service":{{json (.Label "` + labelService + `")}},"state":{{json .State}}}`
	psJoinFormat = `{"name":{{json .Names}},"join_id":{{json (.Label "` + labelJoinID + `")}},"deadline":{{json (.Label "` + labelJoinDeadline + `")}},"state":{{json .State}}}`
)

// joinContainer is a join container docker reports by the engine's
// label.
type joinContainer struct {
	Name     string `json:"name"`
	JoinID   string `json:"join_id"`
	Deadline string `json:"deadline"`
	State    string `json:"state"`
}

// expiry is when the container's own deadline ends; a deadline that
// cannot be read has passed.
func (c joinContainer) expiry() time.Time {
	t, err := time.Parse(time.RFC3339, c.Deadline)
	if err != nil {
		return time.Time{}
	}
	return t
}

// observe reads every container of the project by its compose label.
func (e *Engine) observe(ctx context.Context) ([]Container, error) {
	res, err := e.docker.Run(ctx, Call{Args: []string{"ps", "-a", "--no-trunc", "--filter", "label=" + labelProject + "=" + e.project, "--format", psFormat}, Deadline: probeDeadline})
	if err != nil {
		return nil, fmt.Errorf("docker ps failed (%v): %s", err, lastLine(res.Stderr))
	}
	var out []Container
	for _, line := range strings.Split(string(res.Stdout), "\n") {
		if line = strings.TrimSpace(line); line == "" {
			continue
		}
		var c struct{ Name, Service, State string }
		if err := json.Unmarshal([]byte(line), &c); err != nil {
			return nil, fmt.Errorf("docker ps answered %q: %w", line, err)
		}
		out = append(out, Container{Service: c.Service, Name: c.Name, State: c.State})
	}
	slices.SortFunc(out, func(a, b Container) int { return strings.Compare(a.Name, b.Name) })
	return out, nil
}

// observeJoins reads the project's join containers by the engine's
// label.
func (e *Engine) observeJoins(ctx context.Context) ([]joinContainer, error) {
	res, err := e.docker.Run(ctx, Call{Args: []string{"ps", "-a", "--no-trunc", "--filter", "label=" + labelJoinProject + "=" + e.project, "--format", psJoinFormat}, Deadline: probeDeadline})
	if err != nil {
		return nil, fmt.Errorf("docker ps failed (%v): %s", err, lastLine(res.Stderr))
	}
	var out []joinContainer
	for _, line := range strings.Split(string(res.Stdout), "\n") {
		if line = strings.TrimSpace(line); line == "" {
			continue
		}
		var c joinContainer
		if err := json.Unmarshal([]byte(line), &c); err != nil {
			return nil, fmt.Errorf("docker ps answered %q: %w", line, err)
		}
		out = append(out, c)
	}
	return out, nil
}

// running reports whether a container in state may still serve: anything
// but created, exited and dead, a paused or restarting one included.
func running(state string) bool {
	switch state {
	case "created", "exited", "dead":
		return false
	}
	return true
}

// stopped is the outcome of a stop and verify: whether two reads a
// second apart agreed that none of its services runs, what the last read
// saw running, and why it could not say so.
type stopped struct {
	ok       bool
	observed []string
	why      string
}

// stopAndVerify stops, then removes, every container of services (every
// container of the project when services is nil) and every join
// container, Serve's configuration emptied first, then reads the
// project's containers twice a second apart until both reads show none
// of them running, within StopDeadline, repeating the stop for any a
// late daemon call started meanwhile. A stop command that fails, or reads
// that never agree, answer not ok with what was seen: never "stopped".
func (e *Engine) stopAndVerify(ctx context.Context, services []string) stopped {
	if err := e.closeServe(); err != nil {
		return stopped{why: err.Error()}
	}
	mine := func(c Container) bool { return services == nil || slices.Contains(services, c.Service) }
	read := func() ([]string, []string, error) {
		cs, err := e.observe(ctx)
		if err != nil {
			return nil, nil, err
		}
		js, err := e.observeJoins(ctx)
		if err != nil {
			return nil, nil, err
		}
		var present, live []string
		for _, c := range cs {
			if mine(c) {
				present = append(present, c.Name)
				if running(c.State) {
					live = append(live, c.Name)
				}
			}
		}
		for _, c := range js {
			present = append(present, c.Name)
			if running(c.State) {
				live = append(live, c.Name)
			}
		}
		return present, live, nil
	}
	end := e.now().Add(StopDeadline)
	var last []string
	for {
		present, _, err := read()
		if err != nil {
			return stopped{observed: last, why: err.Error()}
		}
		if len(present) > 0 {
			if why := e.stopRemove(ctx, present); why != "" {
				_, live, _ := read()
				return stopped{observed: live, why: why}
			}
		}
		_, first, err := read()
		if err != nil {
			return stopped{observed: last, why: err.Error()}
		}
		if err := e.sleep(ctx, time.Second); err != nil {
			return stopped{observed: first, why: err.Error()}
		}
		_, second, err := read()
		if err != nil {
			return stopped{observed: first, why: err.Error()}
		}
		if len(first) == 0 && len(second) == 0 {
			return stopped{ok: true}
		}
		last = second
		if len(last) == 0 {
			last = first
		}
		if !e.now().Before(end) {
			return stopped{observed: last, why: "the reads did not agree that it had stopped within " + StopDeadline.String()}
		}
	}
}

// stopRemove stops, then removes, the containers named, answering why
// it failed, or "". A container already gone is not a failure.
func (e *Engine) stopRemove(ctx context.Context, names []string) string {
	for _, cmd := range [][]string{{"stop"}, {"rm", "-f"}} {
		res, err := e.docker.Run(ctx, Call{Args: append(cmd, names...), Deadline: StopDeadline})
		if err != nil && !onlyGone(res.Stderr) {
			return fmt.Sprintf("docker %s failed (%v): %s", cmd[0], err, lastLine(res.Stderr))
		}
	}
	return ""
}

// onlyGone reports whether every error docker wrote says a container no
// longer exists.
func onlyGone(stderr []byte) bool {
	lines := strings.Split(strings.TrimSpace(string(stderr)), "\n")
	if len(lines) == 0 || lines[0] == "" {
		return false
	}
	for _, line := range lines {
		if !strings.Contains(line, "No such container") && !strings.Contains(line, "is already in progress") {
			return false
		}
	}
	return true
}

// cyfrRunning reports whether the project's cyfr container runs.
func cyfrRunning(cs []Container) bool {
	return slices.ContainsFunc(cs, func(c Container) bool { return c.Service == cyfrService && running(c.State) })
}

// anyRunning reports whether any container of the project, or any join
// container, runs.
func anyRunning(cs []Container, js []joinContainer) bool {
	return slices.ContainsFunc(cs, func(c Container) bool { return running(c.State) }) ||
		slices.ContainsFunc(js, func(c joinContainer) bool { return running(c.State) })
}

// containerOf is the name of service's container, if one exists.
func containerOf(cs []Container, service string) (string, bool) {
	for _, c := range cs {
		if c.Service == service {
			return c.Name, true
		}
	}
	return "", false
}
