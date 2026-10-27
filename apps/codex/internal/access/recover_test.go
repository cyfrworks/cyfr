// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package access

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
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
				unhealthyWhen(h, "CYFR_ACCESS=public")
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
			if c.outcome == "rolled_back" && (rc.Code != "access_rolled_back" || !strings.Contains(rc.Payload["reason"], "health check failed")) {
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

// envEdited is access_env_edited's sentence, word for word.
func envEdited(then, env string) string {
	lead := "A change of how CYFR is reached was interrupted, and .env was edited before the change finished. CYFR stopped the stack, checked it stopped, "
	switch then {
	case "started":
		return lead + "left .env as edited, and started CYFR as it says: " + env + ". If that is not how CYFR should be reached, run `cyfr access <mode>`."
	case "not_running":
		return lead + "and left .env as edited, which says: " + env + ". The stack was not running, so nothing was started. Run `cyfr up` to start it as .env says, or `cyfr access <mode>` to choose again."
	case "failed":
		return lead + "and left .env as edited, but CYFR did not start as it says (" + env + "), and everything is stopped. Fix .env, then run `cyfr up`, or run `cyfr access <mode>` to choose again."
	}
	return lead + "and left .env as edited; nothing was started, because .env no longer says one coherent way CYFR is reached. Run `cyfr up` to see what is wrong with it, or `cyfr access <mode>` to choose again."
}

// .env edited during a switch to a head that is neither of the
// journal's: recovery stops and verifies everything, the original cyfr
// included, leaves .env as edited, and the switch failed with
// access_env_edited saying what followed: started as .env says; nothing
// started, the stack not running; the start as .env says failed, all
// stopped; or .env no longer coherent, nothing started.
func TestRecoveryOfAnEnvEditedMidSwitch(t *testing.T) {
	const edited = "only this computer, at http://localhost:4100"
	for _, c := range []struct {
		then, env string
		running   bool
		edit      func(text string) string
		failStart bool
		want      []string
	}{
		{"started", edited, true, func(s string) string { return strings.Replace(s, "CYFR_PORT=4000", "CYFR_PORT=4100", 1) }, false, baseStack},
		{"not_running", edited, false, func(s string) string { return strings.Replace(s, "CYFR_PORT=4000", "CYFR_PORT=4100", 1) }, false, nil},
		{"failed", edited, true, func(s string) string { return strings.Replace(s, "CYFR_PORT=4000", "CYFR_PORT=4100", 1) }, true, slices.DeleteFunc(slices.Clone(baseStack), func(s string) bool { return s == "cyfr" })},
		{"incoherent", "", true, func(s string) string { return strings.Replace(s, "CYFR_ACCESS=local", "CYFR_ACCESS=sideways", 1) }, false, slices.DeleteFunc(slices.Clone(baseStack), func(s string) bool { return s == "cyfr" })},
	} {
		t.Run(c.then, func(t *testing.T) {
			h := newHome(t)
			if c.running {
				h.fake.startStack(t, h.head())
			}
			r := h.request(id(1), publicTarget, "")
			h.killAt("journal:switch:accepted", func(e *Engine) { e.Switch(bg, r) })
			edit := c.edit(h.env())
			writeFile(t, filepath.Join(h.dir, ".env"), []byte(edit))
			if c.failStart {
				unhealthyWhen(h, "CYFR_PORT=4100")
			}
			receipts, err := h.e.Resume(bg)
			if err != nil || len(receipts) != 1 {
				t.Fatalf("resume answered %+v, %v", receipts, err)
			}
			rc := receipts[0]
			payload := map[string]string{"then": c.then, "env": c.env}
			if c.then == "incoherent" {
				delete(payload, "env")
			}
			if rc.State != "completed" || rc.Outcome != "failed" || rc.Code != "access_env_edited" || !mapsEqual(rc.Payload, payload) {
				t.Fatalf("the receipt is %+v", rc)
			}
			if got := rc.Refusal().Message(); got != envEdited(c.then, c.env) {
				t.Errorf("the sentence reads %q", got)
			}
			if (rc.FinalHead != nil) != (c.then == "started" || c.then == "not_running") {
				t.Errorf("the final head is %+v", rc.FinalHead)
			}
			if h.env() != edit {
				t.Error("recovery did not leave .env as edited")
			}
			if got, want := h.fake.runningServices(), slices.Sorted(slices.Values(c.want)); !slices.Equal(got, want) {
				t.Errorf("running %v, want %v", got, want)
			}
			if _, err := os.Stat(filepath.Join(h.dir, stateDir, journalFile)); err == nil {
				t.Error("the journal is left")
			}
		})
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
		if c.Args[0] == "rm" && slices.Contains(c.Args, "cyfr") && !strings.Contains(c.DotEnv, "CYFR_ACCESS=public") {
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
	if _, err := h.e.Start(bg, "up"); refusalCode(err) != "access_outcome_unknown" || !strings.Contains(err.(*Refusal).Message(), "cyfr access --resume") {
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

// A write killed between its temporary file and its rename leaves the
// temporary file, whose name writeDurable chose: of .env, holding its
// secrets, beside it; of the journal and the receipts, under .cyfr/. The
// next command's recovery removes every one.
func TestRecoverySweepsInterruptedWrites(t *testing.T) {
	for _, file := range []string{".env", journalFile, "receipt"} {
		t.Run(file, func(t *testing.T) {
			h := newHome(t)
			h.fake.startStack(t, h.head())
			r := h.request(id(1), publicTarget, "")
			var left string
			h.e.failWrite = func(name, step string) error {
				match := filepath.Base(name) == file || file == "receipt" && strings.Contains(name, receiptsDir)
				if match && step == "rename" && left == "" {
					matches, _ := filepath.Glob(filepath.Join(filepath.Dir(name), tempPattern(name)))
					if len(matches) == 1 {
						left = matches[0]
					}
					runtime.Goexit()
				}
				return nil
			}
			done := make(chan struct{})
			go func() { defer close(done); h.e.Switch(bg, r) }()
			<-done
			h.e.failWrite = nil
			if left == "" {
				t.Fatal("no temporary file was written")
			}
			if _, err := os.Stat(left); err != nil {
				t.Fatalf("the interrupted write left nothing: %v", err)
			}
			h.crash()
			h.open()
			if _, err := h.e.Resume(bg); err != nil {
				t.Fatal(err)
			}
			if _, err := os.Stat(left); err == nil {
				t.Errorf("recovery left %s", left)
			}
		})
	}
}

// An edit that leaves .env incoherent is the person's, and recovery keeps
// it as it is: an invalid setting added after the switch was accepted,
// or after it committed the new head. The switch failed, everything is
// stopped and verified, and access_env_edited says .env is incoherent.
func TestRecoveryKeepsAnIncoherentEdit(t *testing.T) {
	for _, point := range []string{"journal:switch:accepted", "env:commit"} {
		t.Run(point, func(t *testing.T) {
			h := newHome(t)
			h.fake.startStack(t, h.head())
			r := h.request(id(1), publicTarget, "")
			h.killAt(point, func(e *Engine) { e.Switch(bg, r) })
			edit := h.env() + "CYFR_BIND_ADDRESS=not-an-address\n"
			writeFile(t, h.e.envPath(), []byte(edit))
			receipts, err := h.e.Resume(bg)
			if err != nil || len(receipts) != 1 {
				t.Fatalf("resume answered %+v, %v", receipts, err)
			}
			if rc := receipts[0]; rc.Outcome != "failed" || rc.Code != "access_env_edited" || !mapsEqual(rc.Payload, map[string]string{"then": "incoherent"}) {
				t.Errorf("the receipt is %+v", rc)
			}
			if h.env() != edit {
				t.Errorf("recovery rewrote the edited .env:\n%s", h.env())
			}
			if slices.Contains(h.fake.runningServices(), "cyfr") {
				t.Error("cyfr runs on an incoherent .env")
			}
		})
	}
}

// A .env that held no coherent head when a switch was accepted, for a
// setting outside the head keys, and was corrected before recovery holds
// a head now: it is resolved afresh as .env edited meanwhile, left as
// corrected and started as it says when the stack was running
// (access_env_edited then=started), or left stopped when it was not
// (then=not_running). One still incoherent is .env unchanged: the switch
// was not applied and nothing starts.
func TestRecoveryResolvesAHeadCorrectedAfterAcceptance(t *testing.T) {
	const words = "only this computer, at http://localhost:4000"
	for _, c := range []struct {
		name, point string
		running     bool
		correct     bool
		then        string
		want        []string
	}{
		{"corrected, accepted", "journal:switch:accepted", true, true, "started", baseStack},
		{"corrected, stopped", "journal:switch:stopped", true, true, "started", baseStack},
		{"corrected, not running", "journal:switch:accepted", false, true, "not_running", nil},
		{"still incoherent", "journal:switch:accepted", true, false, "", slices.DeleteFunc(slices.Clone(baseStack), func(s string) bool { return s == "cyfr" })},
	} {
		t.Run(c.name, func(t *testing.T) {
			h := newHome(t)
			if c.running {
				h.fake.startStack(t, h.head())
			}
			fixed := h.env()
			incoherent := fixed + "CYFR_BIND_ADDRESS=not-an-address\n"
			writeFile(t, h.e.envPath(), []byte(incoherent))
			r := h.request(id(1), publicTarget, "")
			if r.OldDigest != "" {
				t.Fatalf("the incoherent .env has a head: %s", r.OldDigest)
			}
			if !h.killAt(c.point, func(e *Engine) { e.Switch(bg, r) }) {
				t.Fatalf("never reached %s", c.point)
			}
			env := incoherent
			if c.correct {
				env = fixed
				writeFile(t, h.e.envPath(), []byte(env))
			}
			receipts, err := h.e.Resume(bg)
			if err != nil || len(receipts) != 1 {
				t.Fatalf("resume answered %+v, %v", receipts, err)
			}
			rc := receipts[0]
			if c.then == "" {
				if rc.State != "completed" || rc.Outcome != "not_applied" || rc.Code != "" || rc.FinalHead != nil {
					t.Errorf("the receipt is %+v", rc)
				}
			} else {
				if rc.State != "completed" || rc.Outcome != "failed" || rc.Code != "access_env_edited" || !mapsEqual(rc.Payload, map[string]string{"then": c.then, "env": words}) || rc.FinalHead == nil || rc.FinalHead.Digest() != h.head().Digest() {
					t.Fatalf("the receipt is %+v", rc)
				}
				if got := rc.Refusal().Message(); got != envEdited(c.then, words) {
					t.Errorf("the sentence reads %q", got)
				}
			}
			if h.env() != env {
				t.Errorf("recovery rewrote .env:\n%s", h.env())
			}
			if got, want := h.fake.runningServices(), slices.Sorted(slices.Values(c.want)); !slices.Equal(got, want) {
				t.Errorf("running %v, want %v", got, want)
			}
			if _, err := os.Stat(filepath.Join(h.dir, stateDir, journalFile)); err == nil {
				t.Error("the journal is left")
			}
		})
	}
}

// A COMPOSE_* setting planted in .env while a switch was unfinished does
// not keep recovery from converging, whether the switch's own stop ran or
// not: the project opens, recovery stops and verifies the stack, cyfr
// included, with no compose call (compose would read the setting), then
// refuses with compose_env_refused, starting nothing; the switch stays
// unfinished until .env is fixed.
func TestRecoveryConvergesUnderAComposeSettingInEnv(t *testing.T) {
	for _, point := range []string{"journal:switch:accepted", "journal:switch:stopped"} {
		t.Run(point, func(t *testing.T) {
			h := newHome(t)
			h.fake.startStack(t, h.head())
			r := h.request(id(1), publicTarget, "")
			h.killAt(point, func(e *Engine) { e.Switch(bg, r) })
			h.crash()
			writeFile(t, h.e.envPath(), []byte(h.env()+"COMPOSE_PROFILES=public\n"))
			e, err := Open(h.dir, h.fake)
			if err != nil {
				t.Fatalf("the project does not open: %v", err)
			}
			e.clock = h.clock
			unlock, err := e.Lock("access --resume")
			if err != nil {
				t.Fatal(err)
			}
			defer unlock()
			h.fake.mu.Lock()
			h.fake.st.Containers["home-caddy-1"] = &fakeContainer{Name: "home-caddy-1", Service: "caddy", State: "running"}
			h.fake.mu.Unlock()
			mark := len(h.fake.calls())
			receipts, err := e.Resume(bg)
			if refusalCode(err) != "compose_env_refused" || len(receipts) != 0 {
				t.Fatalf("resume answered %+v, %v", receipts, err)
			}
			calls := h.fake.calls()[mark:]
			reads := 0
			for _, c := range calls {
				if c.Args[0] == "compose" {
					t.Errorf("recovery ran compose, which reads .env: %s", c)
				}
				if c.Args[0] == "ps" {
					reads++
				}
			}
			if reads < 4 {
				t.Errorf("the stop was not verified by two reads: %d", reads)
			}
			if running := h.fake.runningServices(); slices.Contains(running, "cyfr") || slices.Contains(running, "caddy") {
				t.Errorf("running %v", running)
			}
			if j, _ := e.readJournal(); j == nil {
				t.Error("the switch was made terminal before .env could be read")
			}
			for _, op := range []func() error{
				func() error { _, err := e.Start(bg, "up"); return err },
				func() error { _, err := e.Switch(bg, SwitchRequest{ID: id(5)}); return err },
				func() error { _, err := e.Join(bg, JoinRequest{ID: id(6)}); return err },
				func() error { _, err := e.CancelJoin(bg, CancelRequest{ID: id(7), JoinID: id(8)}); return err },
			} {
				before := len(h.fake.calls())
				if err := op(); refusalCode(err) != "compose_env_refused" {
					t.Errorf("a mutating method answered %v", err)
				}
				if after := h.fake.calls()[before:]; len(after) != 0 {
					t.Errorf("a refused method ran docker: %v", after)
				}
			}
		})
	}
}

// With nothing unfinished, a COMPOSE_* setting in .env is refused by
// Resume before any docker call.
func TestResumeRefusesAComposeSettingBeforeDocker(t *testing.T) {
	h := newHome(t)
	writeFile(t, h.e.envPath(), []byte(h.env()+"COMPOSE_PROFILES=public\n"))
	if _, err := h.e.Resume(bg); refusalCode(err) != "compose_env_refused" {
		t.Errorf("resume answered %v", err)
	}
	if calls := h.fake.calls(); len(calls) != 0 {
		t.Errorf("docker ran before the refusal: %v", calls)
	}
}
