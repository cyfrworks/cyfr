// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package reach

import (
	"os"
	"slices"
	"strings"
	"testing"
	"time"
)

// A start while a join waits for its approval is refused with reach_busy
// naming the join, as every other mutating method is: no tailscale
// service starts on the state volume the join container runs on, and
// join.json stays the waiting attempt's.
func TestStartIsRefusedWhileAJoinWaits(t *testing.T) {
	h := newHome(t)
	h.fake.startStack(t, h.head())
	h.toTailnet(1, testKey, false)
	if _, err := h.e.Stop(bg, "down", false); err != nil {
		t.Fatal(err)
	}
	h.killAt("journal:join:waiting", func(e *Engine) { e.Join(bg, JoinRequest{ID: id(3), NewNode: true}) })
	if receipts, err := h.e.Resume(bg); err != nil || len(receipts) != 0 {
		t.Fatalf("resume answered %+v, %v", receipts, err)
	}
	rec, _ := h.e.readJoin()
	before, _ := os.ReadFile(h.e.path(joinFile))
	mark := len(h.fake.calls())
	rc, err := h.e.Start(bg, "up")
	until := rec.Deadline.UTC().Format(time.RFC3339)
	want := "A tailnet join (`" + rec.JoinID + "`) is still waiting for this machine's approval, until `" + until + "` at the latest. Nothing was changed. Approve the machine with the link that join printed, or wait until then, and run this command again."
	if refusalCode(err) != "reach_busy" || rc.State != "rejected" || !mapsEqual(rc.Payload, map[string]string{"join_id": rec.JoinID, "until": until}) || err.(*Refusal).Message() != want {
		t.Fatalf("start answered %+v, %v", rc, err)
	}
	for _, c := range h.fake.calls()[mark:] {
		if c.Args[0] == "compose" && slices.Contains(c.Args, "up") {
			t.Errorf("start ran %s while the join waits", c)
		}
	}
	if after, _ := os.ReadFile(h.e.path(joinFile)); string(after) != string(before) || !slices.Contains(h.fake.runningServices(), "join") {
		t.Errorf("join.json became %s, the join %v", after, h.fake.runningServices())
	}

	// update and restore cancel the waiting join first, then start.
	if err := h.e.CancelWaitingJoin(bg); err != nil {
		t.Fatal(err)
	}
	if _, err := h.e.Start(bg, "update"); refusalCode(err) == "reach_busy" {
		t.Errorf("a start after the join was cancelled answered %v", err)
	}
}

// A switch from a home whose .env is incoherent stops every reach mode's
// service, its proxy included, though the old head cannot name it.
func TestSwitchFromAnIncoherentEnvStopsEveryReachService(t *testing.T) {
	h := newHome(t)
	h.fake.startStack(t, h.head())
	h.e.Switch(bg, h.request(id(1), publicTarget, ""))
	if !slices.Contains(h.fake.runningServices(), "caddy") {
		t.Fatal("caddy does not run")
	}
	writeFile(t, h.e.envPath(), []byte(strings.Replace(h.env(), "CYFR_REACH=public", "CYFR_REACH=sideways", 1)))
	r := h.request(id(2), Target{Mode: ModeLocal}, "")
	if r.OldDigest != "" {
		t.Fatalf("the incoherent .env has a head: %s", r.OldDigest)
	}
	mark := len(h.fake.calls())
	if rc, err := h.e.Switch(bg, r); err != nil || rc.Outcome != "ok" {
		t.Fatalf("switch answered %+v, %v", rc, err)
	}
	h.assertConverged(baseStack...)
	calls := h.fake.calls()[mark:]
	stop := slices.IndexFunc(calls, func(c fakeCall) bool { return c.Args[0] == "stop" && slices.Contains(c.Args, "home-caddy-1") })
	commit := slices.IndexFunc(calls, func(c fakeCall) bool { return strings.Contains(c.DotEnv, "CYFR_REACH=local") })
	if stop < 0 || commit < stop {
		t.Errorf("caddy was not stopped before the commit (stop %d, commit %d)", stop, commit)
	}
}

// A start removes, verified, a running reach service its head does not
// select before it starts: a public home's leftover tailscale goes.
func TestStartRemovesAReachServiceItsHeadDoesNotSelect(t *testing.T) {
	h := newHome(t)
	h.fake.startStack(t, h.head())
	h.e.Switch(bg, h.request(id(1), publicTarget, ""))
	h.fake.st.Containers["home-tailscale-1"] = &fakeContainer{Name: "home-tailscale-1", Service: serveService, State: "running", Volume: stateVolume}
	mark := len(h.fake.calls())
	if rc, err := h.e.Start(bg, "up"); err != nil || rc.Outcome != "ok" {
		t.Fatalf("start answered %+v, %v", rc, err)
	}
	h.assertConverged(publicStack...)
	calls := h.fake.calls()[mark:]
	rm := slices.IndexFunc(calls, func(c fakeCall) bool { return c.Args[0] == "rm" && slices.Contains(c.Args, "home-tailscale-1") })
	up := slices.IndexFunc(calls, func(c fakeCall) bool { return c.Args[0] == "compose" && slices.Contains(c.Args, "up") })
	if rm < 0 || up < rm {
		t.Errorf("the leftover tailscale was not removed before the start (rm %d, up %d)", rm, up)
	}
	reads := 0
	for _, c := range calls[max(rm, 0):max(up, 0)] {
		if c.Args[0] == "ps" {
			reads++
		}
	}
	if reads < 4 {
		t.Errorf("the removal was not verified by two reads before the start: %d", reads)
	}
}

// A stop under an incoherent .env covers every reach mode's service, not
// only cyfr and the journal's.
func TestStopUnderAnIncoherentEnvStopsEveryReachService(t *testing.T) {
	h := newHome(t)
	h.fake.startStack(t, h.head())
	h.e.Switch(bg, h.request(id(1), publicTarget, ""))
	writeFile(t, h.e.envPath(), []byte(strings.Replace(h.env(), "CYFR_REACH=public", "CYFR_REACH=sideways", 1)))
	if rc, err := h.e.Stop(bg, "update", false); err != nil || rc.Outcome != "ok" {
		t.Fatalf("stop answered %+v, %v", rc, err)
	}
	if running := h.fake.runningServices(); slices.Contains(running, "caddy") || slices.Contains(running, "cyfr") {
		t.Errorf("running %v after the stop", running)
	}
}

// Recovery's stop covers every reach mode's service, beyond the services
// its journal names: a proxy started after a stopped-stack switch was
// accepted is stopped too.
func TestRecoveryStopsEveryReachService(t *testing.T) {
	h := newHome(t)
	r := h.request(id(1), publicTarget, "")
	h.killAt("journal:switch:accepted", func(e *Engine) { e.Switch(bg, r) })
	h.fake.st.Containers["home-caddy-1"] = &fakeContainer{Name: "home-caddy-1", Service: "caddy", State: "running"}
	if _, err := h.e.Resume(bg); err != nil {
		t.Fatal(err)
	}
	if slices.Contains(h.fake.runningServices(), "caddy") {
		t.Error("recovery left caddy running")
	}
}
