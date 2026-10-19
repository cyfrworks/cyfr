// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package reach

import (
	"context"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"time"
)

// started is the outcome of a start: ok; or why it failed; or the
// refusal of a tailnet machine that is not the head's, with cyfr running
// and Serve closed.
type started struct {
	ok       bool
	why      string
	mismatch *Refusal
	content  []byte
}

// startHead is the start path, every start's: Serve closed; h
// materialized afresh and its stack checked; cyfr started (with every
// other service of h's selection when full, alone otherwise), then h's
// reach services; cyfr's health awaited; then, in tailnet, the running
// machine validated against h before Serve opens.
func (e *Engine) startHead(ctx context.Context, h Head, j *journal, full bool) started {
	if err := e.closeServe(); err != nil {
		return started{why: err.Error()}
	}
	e.reached("start:" + h.Mode)
	content, err := e.materialize(ctx, h, j)
	if err != nil {
		if r, ok := err.(*Refusal); ok {
			return started{why: r.Message()}
		}
		return started{why: err.Error()}
	}
	c, err := parseConfig(content)
	if err != nil {
		return started{why: err.Error(), content: content}
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
	if why := e.waitHealthy(ctx); why != "" {
		return started{why: why, content: content}
	}
	if h.Mode == ModeTailnet {
		mismatch, err := e.validateNode(ctx, h)
		if err != nil {
			return started{why: err.Error(), content: content}
		}
		if mismatch != nil {
			return started{mismatch: mismatch, content: content}
		}
		if err := e.openServe(proxyPort(c)); err != nil {
			return started{why: err.Error(), content: content}
		}
	}
	return started{ok: true, content: content}
}

// compose runs a compose command of h on its materialized file,
// answering why it failed, or "".
func (e *Engine) compose(ctx context.Context, h Head, deadline time.Duration, args ...string) string {
	res, err := e.docker.Run(ctx, Call{Args: e.composeArgs(h, args...), Deadline: deadline})
	if err != nil {
		return fmt.Sprintf("docker compose %s failed (%v): %s", strings.Join(args[:min(len(args), 2)], " "), err, lastLine(res.Stderr))
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
// healthy, within HealthDeadline, answering why it did not, or "".
func (e *Engine) waitHealthy(ctx context.Context) string {
	end := e.now().Add(HealthDeadline)
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
			return fmt.Sprintf("cyfr was not healthy within %s (%s)", HealthDeadline, last)
		}
		if err := e.sleep(ctx, time.Second); err != nil {
			return err.Error()
		}
	}
}
