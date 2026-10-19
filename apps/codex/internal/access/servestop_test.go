// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package access

import (
	"context"
	"os"
	"slices"
	"strings"
	"testing"
)

// stopsTheHome reports whether a docker call stops, removes or takes down
// a container of the home: a join container, which never serves, aside.
func stopsTheHome(args []string) bool {
	verbs := []string{"stop", "rm", "kill", "restart", "down"}
	if args[0] == "compose" {
		return slices.ContainsFunc(args, func(a string) bool { return slices.Contains(verbs, a) })
	}
	return slices.Contains(verbs, args[0]) && !slices.ContainsFunc(args[1:], func(a string) bool { return strings.Contains(a, "-tailnet-join-") })
}

// No docker call of the engine's that stops a container of the home runs
// while Serve forwards to it: with Serve held open before each path that
// stops (a stop, `cyfr down`, a switch and its rollback, a start that
// removes an access service its head does not select, a join that replaces
// the machine's service, recovery), every such call finds it closed.
func TestEveryStopOfTheHomeFindsServeClosed(t *testing.T) {
	h := newHome(t)
	h.fake.startStack(t, h.head())
	h.toTailnet(1, testKey, false)
	open := func() { writeFile(t, h.e.servePath(), []byte(serveOpen(4401))) }
	stops := map[string]int{}
	path := ""
	failCaddy := false
	h.fake.hook = func(_ context.Context, c *fakeCall) *fakeAnswer {
		if stopsTheHome(c.Args) {
			stops[path]++
			if data, _ := os.ReadFile(h.e.servePath()); string(data) != serveClosed {
				t.Errorf("%s: %s ran while Serve held %s", path, c, data)
			}
		}
		if failCaddy && c.Args[0] == "compose" && slices.Contains(c.Args, "up") && slices.Contains(c.Args, "caddy") {
			return &fakeAnswer{Code: 1}
		}
		return nil
	}
	run := func(name string, op func()) {
		t.Helper()
		path = name
		open()
		op()
		if stops[name] == 0 {
			t.Errorf("%s stopped nothing", name)
		}
	}

	run("stop", func() { h.e.Stop(bg, "stop", false) })
	h.e.Start(bg, "up")
	run("down", func() { h.e.Stop(bg, "down", true) })
	h.e.Start(bg, "up")
	run("start removing a service its head does not select", func() {
		h.fake.startStack(t, Head{Profiles: []string{ModePublic}})
		h.e.Start(bg, "up")
	})
	run("switch", func() {
		if rc, err := h.e.Switch(bg, h.request(id(10), Target{Mode: ModeLocal}, "")); err != nil || rc.Outcome != "ok" {
			t.Fatalf("the switch to local answered %+v, %v", rc, err)
		}
	})
	run("rollback", func() {
		failCaddy = true
		h.e.hook = func(point string) {
			if point == "journal:switch:rolling_back" {
				open()
			}
		}
		if rc, _ := h.e.Switch(bg, h.request(id(11), publicTarget, "")); rc.Outcome != "rolled_back" {
			t.Errorf("the failed switch answered %+v", rc)
		}
		failCaddy, h.e.hook = false, nil
	})
	run("join replacing the machine's service", func() {
		h.fake.startStack(t, Head{Profiles: []string{ModeTailnet}})
		h.e.hook = func(point string) {
			if point == "journal:join:accepted" {
				open()
			}
		}
		h.join(12, testKey, true)
		h.e.hook = nil
	})
	h.e.Start(bg, "up")
	r := h.request(id(14), publicTarget, "")
	run("recovery", func() {
		if !h.killAt("journal:switch:accepted", func(e *Engine) { e.Switch(bg, r) }) {
			t.Fatal("the switch never reached its acceptance")
		}
		open()
		if _, err := h.e.Resume(bg); err != nil {
			t.Fatal(err)
		}
	})
}
