// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package reach

import (
	"context"
	"encoding/json"
	"fmt"
	"slices"
	"strconv"
	"strings"
	"time"
)

// started is the outcome of a start: ok; or why it failed; or, with
// cyfr running and healthy and Serve closed, the refusal of a tailnet
// machine that cannot serve the head: local.
type started struct {
	ok      bool
	why     string
	local   *Refusal
	content []byte
	// refused is the stack check's refusal, made before anything was
	// written or started.
	refused *Refusal
}

// identityMismatch reports whether a local start found another machine
// than the head's, rather than one that has not joined or has HTTPS off.
func (s started) identityMismatch() bool {
	return s.local != nil && s.local.Code == "tailnet_node_mismatch"
}

// startHead is the start path, every start's: h materialized afresh and
// its stack checked; Serve closed; cyfr started (with every
// other service of h's selection when full, alone otherwise), then h's
// reach services; cyfr's health awaited within health; then, in tailnet,
// the running machine validated against h before Serve opens.
func (e *Engine) startHead(ctx context.Context, h Head, j *journal, full bool, health time.Duration) started {
	e.reached("start:" + h.Mode)
	content, err := e.materialize(ctx, h, j)
	if err != nil {
		if r, ok := err.(*Refusal); ok {
			return started{why: r.Message(), refused: r}
		}
		return started{why: err.Error()}
	}
	if err := e.closeServe(); err != nil {
		return started{why: err.Error(), content: content}
	}
	c, err := parseConfig(content)
	if err != nil {
		return started{why: err.Error(), content: content}
	}
	if why := e.removeUnselected(ctx, c, h); why != "" {
		return started{why: why, content: content}
	}
	first := []string{"up", "-d", "--no-deps", cyfrService}
	if full {
		first = append([]string{"up", "-d"}, otherServices(c, h)...)
	}
	if why := e.compose(ctx, h, StartDeadline, first...); why != "" {
		return started{why: why, content: content}
	}
	if reach := reachServices(c, h); len(reach) > 0 {
		if why := e.compose(ctx, h, StartDeadline, append([]string{"up", "-d", "--no-deps"}, reach...)...); why != "" {
			return started{why: why, content: content}
		}
	}
	if why := e.waitHealthy(ctx, health); why != "" {
		return started{why: why, content: content}
	}
	if h.Mode == ModeTailnet {
		ref, err := e.validateNode(ctx, h)
		if err != nil {
			return started{why: err.Error(), content: content}
		}
		if ref != nil {
			if rec, _ := e.readJoin(); ref.Code == "tailnet_not_joined" && rec != nil && (rec.State == "joined" || rec.State == "https_off") {
				// The state holds no machine: the join record names
				// one that is gone, and must not be offered again. An
				// attempt in progress is never this record.
				e.removeDurable(e.path(joinFile))
			}
			return started{local: ref, content: content}
		}
		if err := e.openServe(proxyPort(c)); err != nil {
			return started{why: err.Error(), content: content}
		}
	}
	return started{ok: true, content: content}
}

// removeUnselected stops and removes, verified, every running reach
// service h does not select, a proxy another head left: h's home is
// reached only as h says.
func (e *Engine) removeUnselected(ctx context.Context, c config, h Head) string {
	every, err := e.everyReachService(ctx)
	if err != nil {
		return err.Error()
	}
	selected := reachServices(c, h)
	unselected := slices.DeleteFunc(every, func(s string) bool { return slices.Contains(selected, s) })
	cs, err := e.observe(ctx)
	if err != nil {
		return err.Error()
	}
	if !slices.ContainsFunc(cs, func(c Container) bool { return slices.Contains(unselected, c.Service) && running(c.State) }) {
		return ""
	}
	if s := e.stopAndVerify(ctx, unselected); !s.ok {
		return "a reach service this home does not select is still running (" + observedText(s.observed) + "): " + s.why
	}
	return ""
}

// compose runs a compose command of h on its materialized file,
// answering why it failed, or "".
func (e *Engine) compose(ctx context.Context, h Head, deadline time.Duration, args ...string) string {
	res, err := e.docker.Run(ctx, Call{Args: e.composeArgs(h, args...), Deadline: deadline})
	if err != nil {
		return e.callFailed("docker compose "+strings.Join(args[:min(len(args), 2)], " "), err, res.Stderr)
	}
	return ""
}

// proxyPort is the port cyfr's proxy listener takes in c.
func proxyPort(c config) int {
	if n, err := strconv.Atoi(cyfrEnv(c)["CYFR_PROXY_PORT"]); err == nil && n > 0 {
		return n
	}
	return 4001
}

// waitHealthy waits for the cyfr container's Docker health to read
// healthy, within limit, answering why it did not, or "".
func (e *Engine) waitHealthy(ctx context.Context, limit time.Duration) string {
	end := e.now().Add(limit)
	last := "it was not found"
	for {
		cs, err := e.observe(ctx)
		if err != nil {
			last = err.Error()
		} else if name, ok := containerOf(cs, cyfrService); ok {
			res, err := e.docker.Run(ctx, Call{Args: []string{"inspect", "--format", "{{json .State}}", name}, Deadline: probeDeadline})
			var st struct {
				Status   string
				ExitCode int
				Health   *struct{ Status string }
			}
			switch {
			case err != nil:
				last = fmt.Sprintf("docker inspect failed (%v)", err)
			case json.Unmarshal(res.Stdout, &st) != nil:
				last = "docker inspect answered what is not its JSON"
			case st.Status == "exited" || st.Status == "dead":
				return fmt.Sprintf("cyfr exited with status %d before it was healthy", st.ExitCode)
			case st.Health == nil:
				last = "cyfr has no health check"
			case st.Health.Status == "healthy":
				return ""
			case st.Health.Status == "unhealthy":
				return "cyfr's health check failed"
			default:
				last = "its health is " + st.Health.Status
			}
		}
		if !e.now().Before(end) {
			return fmt.Sprintf("cyfr was not healthy within %s (%s)", limit, last)
		}
		if err := e.sleep(ctx, time.Second); err != nil {
			return err.Error()
		}
	}
}
