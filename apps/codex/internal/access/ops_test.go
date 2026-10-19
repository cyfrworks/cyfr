// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package access

import (
	"context"
	"os"
	"slices"
	"strings"
	"testing"
	"time"
)

// A start while a join waits for its approval is refused with access_busy
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
	if refusalCode(err) != "access_busy" || rc.State != "rejected" || !mapsEqual(rc.Payload, map[string]string{"join_id": rec.JoinID, "until": until}) || err.(*Refusal).Message() != want {
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
	if _, err := h.e.Start(bg, "update"); refusalCode(err) == "access_busy" {
		t.Errorf("a start after the join was cancelled answered %v", err)
	}
}

// A switch from a home whose .env is incoherent stops every access mode's
// service, its proxy included, though the old head cannot name it.
func TestSwitchFromAnIncoherentEnvStopsEveryAccessService(t *testing.T) {
	h := newHome(t)
	h.fake.startStack(t, h.head())
	h.e.Switch(bg, h.request(id(1), publicTarget, ""))
	if !slices.Contains(h.fake.runningServices(), "caddy") {
		t.Fatal("caddy does not run")
	}
	writeFile(t, h.e.envPath(), []byte(strings.Replace(h.env(), "CYFR_ACCESS=public", "CYFR_ACCESS=sideways", 1)))
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
	commit := slices.IndexFunc(calls, func(c fakeCall) bool { return strings.Contains(c.DotEnv, "CYFR_ACCESS=local") })
	if stop < 0 || commit < stop {
		t.Errorf("caddy was not stopped before the commit (stop %d, commit %d)", stop, commit)
	}
}

// A start removes, verified, a running access service its head does not
// select before it starts: a public home's leftover tailscale goes.
func TestStartRemovesAnAccessServiceItsHeadDoesNotSelect(t *testing.T) {
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

// A stop under an incoherent .env covers every access mode's service, not
// only cyfr and the journal's.
func TestStopUnderAnIncoherentEnvStopsEveryAccessService(t *testing.T) {
	h := newHome(t)
	h.fake.startStack(t, h.head())
	h.e.Switch(bg, h.request(id(1), publicTarget, ""))
	writeFile(t, h.e.envPath(), []byte(strings.Replace(h.env(), "CYFR_ACCESS=public", "CYFR_ACCESS=sideways", 1)))
	if rc, err := h.e.Stop(bg, "update", false); err != nil || rc.Outcome != "ok" {
		t.Fatalf("stop answered %+v, %v", rc, err)
	}
	if running := h.fake.runningServices(); slices.Contains(running, "caddy") || slices.Contains(running, "cyfr") {
		t.Errorf("running %v after the stop", running)
	}
}

// Recovery's stop covers every access mode's service, beyond the services
// its journal names: a proxy started after a stopped-stack switch was
// accepted is stopped too.
func TestRecoveryStopsEveryAccessService(t *testing.T) {
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

// Every stop closes Serve first: `cyfr down`'s compose down never runs
// while Serve still forwards to the home.
func TestStopClosesServeBeforeComposeDown(t *testing.T) {
	h := newHome(t)
	h.fake.startStack(t, h.head())
	h.toTailnet(1, testKey, false)
	downs := 0
	h.fake.hook = func(_ context.Context, c *fakeCall) *fakeAnswer {
		if c.Args[0] == "compose" && slices.Contains(c.Args, "down") {
			downs++
			if data, _ := os.ReadFile(h.e.servePath()); string(data) != serveClosed {
				t.Errorf("compose down ran while Serve held %s", data)
			}
		}
		return nil
	}
	if _, err := h.e.Stop(bg, "down", true); err != nil {
		t.Fatal(err)
	}
	if downs != 1 {
		t.Errorf("compose down ran %d times", downs)
	}
}

// CloseServe empties Serve's configuration durably, as every stop path
// does first, and requires the lock.
func TestCloseServe(t *testing.T) {
	h := newHome(t)
	h.fake.startStack(t, h.head())
	h.toTailnet(1, testKey, false)
	other, _ := Open(h.dir, h.fake)
	if err := other.CloseServe(bg); err == nil || !strings.Contains(err.Error(), "lock is not held") {
		t.Errorf("CloseServe without the lock answered %v", err)
	}
	if err := h.e.CloseServe(bg); err != nil {
		t.Fatal(err)
	}
	if got, _ := os.ReadFile(h.e.servePath()); string(got) != serveClosed {
		t.Errorf("Serve's configuration is %s", got)
	}
}

// A stop under a .env that sets a COMPOSE_* key makes no compose call,
// which would read it, and stops every container of the project, since
// without compose it cannot name the access services.
func TestStopUnderAComposeSettingStopsEverything(t *testing.T) {
	h := newHome(t)
	h.fake.startStack(t, h.head())
	h.e.Switch(bg, h.request(id(1), publicTarget, ""))
	writeFile(t, h.e.envPath(), []byte(h.env()+"COMPOSE_PROFILES=tailnet\n"))
	mark := len(h.fake.calls())
	if rc, err := h.e.Stop(bg, "down", false); err != nil || rc.Outcome != "ok" {
		t.Fatalf("stop answered %+v, %v", rc, err)
	}
	for _, c := range h.fake.calls()[mark:] {
		if c.Args[0] == "compose" {
			t.Errorf("stop ran compose: %s", c)
		}
	}
	if running := h.fake.runningServices(); len(running) != 0 {
		t.Errorf("running %v", running)
	}
}
