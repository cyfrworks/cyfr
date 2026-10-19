// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package reach

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

var publicTarget = Target{Mode: ModePublic, Domain: "home.example.com"}

// unhealthyWhen makes cyfr's health fail while .env holds line.
func unhealthyWhen(h *testHome, line string) {
	h.fake.hook = func(_ context.Context, c *fakeCall) *fakeAnswer {
		h.fake.mu.Lock()
		defer h.fake.mu.Unlock()
		h.fake.st.Health = "healthy"
		if envNow(h.dir, line) {
			h.fake.st.Health = "unhealthy"
		}
		return nil
	}
}

// A switch killed at any phase is recovered by the next command's
// Resume: before the commit the old head starts again (not_applied),
// after it the switch rolls forward (ok), and a rollback finishes with
// the target stopped first and its reason kept; a kill after the receipt
// replays nothing. Each ends with
// one coherent head running, its receipt, and no journal or file left.
func TestKillAtEveryPhaseRecovers(t *testing.T) {
	for _, c := range []struct {
		point, outcome string
		unhealthy      bool
		running        []string
	}{
		{"journal:switch:accepted", "not_applied", false, baseStack},
		{"journal:switch:stopped", "not_applied", false, baseStack},
		{"env:commit", "ok", false, publicStack},
		{"journal:switch:committed", "ok", false, publicStack},
		{"start:public", "ok", false, publicStack},
		{"receipt:switch", "ok", false, publicStack},
		{"journal:switch:rolling_back", "rolled_back", true, baseStack},
		{"env:rollback", "rolled_back", true, baseStack},
		{"journal:switch:restored", "rolled_back", true, baseStack},
	} {
		t.Run(c.point, func(t *testing.T) {
			h := newHome(t)
			h.fake.startStack(t, h.head())
			if c.unhealthy {
				unhealthyWhen(h, "CYFR_REACH=public")
			}
			r := h.request(id(1), publicTarget, "")
			if !h.killAt(c.point, func(e *Engine) { e.Switch(bg, r) }) {
				t.Fatalf("the switch never reached %s", c.point)
			}
			before := len(h.fake.calls())
			receipts, err := h.e.Resume(bg)
			if err != nil {
				t.Fatal(err)
			}
			rc, _, _ := h.e.Receipt(id(1))
			if rc.State != "completed" || rc.Outcome != c.outcome {
				t.Errorf("the receipt is %+v, want %s (resume answered %+v)", rc, c.outcome, receipts)
			}
			if c.outcome == "rolled_back" && (rc.Code != "reach_rolled_back" || !strings.Contains(rc.Payload["reason"], "health check failed")) {
				t.Errorf("the rollback's receipt is %+v", rc)
			}
			h.assertConverged(c.running...)
			calls := h.fake.calls()[before:]
			if c.point == "receipt:switch" {
				if i := slices.IndexFunc(calls, func(c fakeCall) bool { return c.Args[0] != "ps" }); i >= 0 {
					t.Errorf("a switch whose receipt was durable was replayed: %s", calls[i])
				}
				return
			}
			// Recovery stops and verifies before anything starts.
			up := slices.IndexFunc(calls, func(c fakeCall) bool { return slices.Contains(c.Args, "up") })
			reads := 0
			for _, call := range calls[:max(up, 0)] {
				if call.Args[0] == "ps" {
					reads++
				}
			}
			if up >= 0 && reads < 4 {
				t.Errorf("recovery started %s before two verifying reads", calls[up])
			}
		})
	}
}

// Killed after acceptance and before the stop, with
// .env corrupted meanwhile, recovery stops the original cyfr too, and
// starts nothing it cannot validate: the switch failed, everything is
// stopped and checked stopped.
func TestRecoveryWithACorruptEnvStopsEverything(t *testing.T) {
	h := newHome(t)
	h.fake.startStack(t, h.head())
	r := h.request(id(1), publicTarget, "")
	h.killAt("journal:switch:accepted", func(e *Engine) { e.Switch(bg, r) })
	writeFile(t, filepath.Join(h.dir, ".env"), []byte(strings.Replace(h.env(), "CYFR_REACH=local", "CYFR_REACH=sideways", 1)))
	receipts, err := h.e.Resume(bg)
	if err != nil || len(receipts) != 1 {
		t.Fatalf("resume answered %+v, %v", receipts, err)
	}
	rc := receipts[0]
	if rc.Outcome != "failed" || rc.Code != "reach_failed" || !strings.Contains(rc.Payload["env"], "CYFR_REACH is `sideways`") {
		t.Errorf("the receipt is %+v", rc)
	}
	if slices.Contains(h.fake.runningServices(), "cyfr") {
		t.Error("the original cyfr still runs")
	}
	if _, err := os.Stat(filepath.Join(h.dir, stateDir, journalFile)); err == nil {
		t.Error("the journal is left")
	}
}

// .env edited during the switch to a head that is neither of the
// journal's: recovery starts what .env holds, since it validates, and the
// switch failed with the words .env now holds.
func TestRecoveryStartsAnEditedEnv(t *testing.T) {
	h := newHome(t)
	h.fake.startStack(t, h.head())
	r := h.request(id(1), publicTarget, "")
	h.killAt("journal:switch:stopped", func(e *Engine) { e.Switch(bg, r) })
	writeFile(t, filepath.Join(h.dir, ".env"), []byte(strings.Replace(h.env(), "CYFR_PORT=4000", "CYFR_PORT=4100", 1)))
	receipts, err := h.e.Resume(bg)
	if err != nil || len(receipts) != 1 {
		t.Fatalf("resume answered %+v, %v", receipts, err)
	}
	if rc := receipts[0]; rc.Outcome != "failed" || rc.Code != "reach_stale" || !strings.Contains(rc.Payload["words"], "http://localhost:4100") {
		t.Errorf("the receipt is %+v", rc)
	}
	h.assertConverged(baseStack...)
	if h.head().Port != 4100 {
		t.Error("the edited head is not .env's")
	}
}

// A late daemon call: a start the client lost lands after the stop,
// between the two reads that verify it. The reads disagree, the stop is
// repeated for what landed, and the stop is verified only once two reads
// agree.
func TestLateDaemonCompletionConverges(t *testing.T) {
	h := newHome(t)
	h.fake.startStack(t, h.head())
	r := h.request(id(1), publicTarget, "")
	landed := false
	h.fake.hook = func(_ context.Context, c *fakeCall) *fakeAnswer {
		h.fake.mu.Lock()
		defer h.fake.mu.Unlock()
		removed, reads := false, 0
		for _, call := range h.fake.st.Calls {
			switch {
			case call.Args[0] == "rm":
				removed = true
			case removed && call.Args[0] == "ps" && strings.Contains(call.String(), labelProject):
				reads++
			}
		}
		// The first verifying read is clean; the start lands before the
		// second.
		if !landed && removed && reads == 1 && c.Args[0] == "ps" && strings.Contains(c.String(), labelProject) {
			landed = true
			h.fake.st.Containers["cyfr"] = &fakeContainer{Name: "cyfr", Service: "cyfr", State: "running", Health: "healthy"}
		}
		return nil
	}
	rc, err := h.e.Switch(bg, r)
	if err != nil || rc.Outcome != "ok" {
		t.Fatalf("switch answered %+v, %v", rc, err)
	}
	if !landed {
		t.Fatal("the late start never landed")
	}
	rms := 0
	for _, c := range h.fake.calls() {
		if c.Args[0] == "rm" && slices.Contains(c.Args, "cyfr") && !strings.Contains(c.DotEnv, "CYFR_REACH=public") {
			rms++
		}
	}
	if rms < 2 {
		t.Errorf("the late cyfr was not stopped again before the commit (%d removals)", rms)
	}
	h.assertConverged(publicStack...)
}

// A durable write that fails around its rename or its directory sync, at
// the journal, .env or the receipt, leaves state that the next command's
// recovery turns into one head: .env holds the old or the new head, the
// stack runs it, and no journal is left.
func TestFailedDurableWritesRecoverToOneHead(t *testing.T) {
	for _, file := range []struct {
		name string
		nth  int
	}{{journalFile, 1}, {journalFile, 2}, {journalFile, 3}, {".env", 1}, {"receipt", 1}} {
		for _, step := range []string{"rename", "sync"} {
			t.Run(fmt.Sprintf("%s#%d/%s", file.name, file.nth, step), func(t *testing.T) {
				h := newHome(t)
				h.fake.startStack(t, h.head())
				old := h.head()
				r := h.request(id(1), publicTarget, "")
				seen := 0
				injected := false
				h.e.failWrite = func(name, at string) error {
					match := filepath.Base(name) == file.name || file.name == "receipt" && strings.Contains(name, receiptsDir)
					if !match || at != step || injected {
						return nil
					}
					if seen++; seen == file.nth {
						injected = true
						return errors.New("injected: the disk failed")
					}
					return nil
				}
				h.e.Switch(bg, r)
				if !injected {
					t.Fatal("the write never happened")
				}
				h.crash()
				h.open()
				if _, err := h.e.Resume(bg); err != nil {
					t.Fatal(err)
				}
				got := h.head()
				switch got.Digest() {
				case old.Digest():
					h.assertConverged(baseStack...)
				case r.NewDigest:
					h.assertConverged(publicStack...)
				default:
					t.Fatalf(".env holds neither head: %+v", got)
				}
			})
		}
	}
}

// The start path refuses while the journal holds an unfinished operation:
// only recovery may finish it.
func TestStartWaitsForRecovery(t *testing.T) {
	h := newHome(t)
	h.fake.startStack(t, h.head())
	r := h.request(id(1), publicTarget, "")
	h.killAt("journal:switch:stopped", func(e *Engine) { e.Switch(bg, r) })
	before := len(h.fake.calls())
	if _, err := h.e.Start(bg, "up"); refusalCode(err) != "reach_outcome_unknown" || !strings.Contains(err.(*Refusal).Message(), "cyfr reach --resume") {
		t.Errorf("start answered %v", err)
	}
	if calls := h.fake.calls()[before:]; len(calls) != 0 {
		t.Errorf("a refused start ran docker: %v", calls)
	}
	if _, err := h.e.Resume(bg); err != nil {
		t.Fatal(err)
	}
	if rc, err := h.e.Start(bg, "up"); err != nil || rc.Outcome != "ok" {
		t.Errorf("start after recovery answered %+v, %v", rc, err)
	}
	h.assertConverged(baseStack...)
}
