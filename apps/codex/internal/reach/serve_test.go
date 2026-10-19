// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package reach

import (
	"context"
	"os"
	"slices"
	"strings"
	"testing"
)

// A tailnet start whose machine is not the one .env names leaves Serve
// closed and cyfr running, answering tailnet_node_mismatch with both
// names; the comparison is byte for byte, the node id's case included.
func TestNodeMismatchLeavesServeClosedAndCyfrRunning(t *testing.T) {
	for _, c := range []struct {
		name        string
		rename      func(n *fakeNode)
		node, inEnv string
	}{
		{"renamed", func(n *fakeNode) { n.Name = "other.tail1234.ts.net" }, "other.tail1234.ts.net", "cyfr.tail1234.ts.net"},
		{"re-identified", func(n *fakeNode) { n.ID = "N0001CNTRL" }, "cyfr.tail1234.ts.net (node N0001CNTRL)", "cyfr.tail1234.ts.net (node n0001CNTRL)"},
	} {
		t.Run(c.name, func(t *testing.T) {
			h := newHome(t)
			h.fake.startStack(t, h.head())
			h.toTailnet(1, testKey, false)
			if _, err := h.e.Stop(bg, "down", false); err != nil {
				t.Fatal(err)
			}
			c.rename(h.fake.st.Volumes[stateVolume])
			rc, err := h.e.Start(bg, "up")
			if refusalCode(err) != "tailnet_node_mismatch" || rc.State != "completed" || rc.Outcome != "started_local" || rc.Payload["node"] != c.node || rc.Payload["env"] != c.inEnv {
				t.Fatalf("start answered %+v, %v", rc, err)
			}
			if rc.Refusal().Code != "tailnet_node_mismatch" {
				t.Errorf("the receipt's refusal is %v", rc.Refusal())
			}
			if !strings.Contains(err.(*Refusal).Message(), "it answers on this machine only") {
				t.Errorf("the sentence reads %q", err.(*Refusal).Message())
			}
			if got, _ := os.ReadFile(h.e.servePath()); string(got) != serveClosed {
				t.Errorf("Serve's configuration is %s", got)
			}
			if !slices.Contains(h.fake.runningServices(), "cyfr") {
				t.Error("cyfr does not run")
			}
		})
	}
}

// A start on a stack already served writes Serve's empty configuration
// before it starts anything: a machine that is no longer .env's is never
// served while it is checked.
func TestStartClosesServeBeforeItStarts(t *testing.T) {
	h := newHome(t)
	h.fake.startStack(t, h.head())
	h.toTailnet(1, testKey, false)
	h.fake.st.Volumes[stateVolume].Name = "other.tail1234.ts.net"
	mark := len(h.fake.calls())
	if _, err := h.e.Start(bg, "up"); refusalCode(err) != "tailnet_node_mismatch" {
		t.Fatalf("start answered %v", err)
	}
	for _, c := range h.fake.calls()[mark:] {
		if slices.Contains(c.Args, "up") && c.Serve != serveClosed {
			t.Errorf("compose up while Serve held %q", c.Serve)
		}
	}
	if got, _ := os.ReadFile(h.e.servePath()); string(got) != serveClosed {
		t.Errorf("Serve's configuration is %s", got)
	}
}

// Validation trusts only two reads a second apart that agree: a first
// read naming another machine is not taken for the machine.
func TestNodeValidationWaitsForAgreeingReads(t *testing.T) {
	h := newHome(t)
	h.fake.startStack(t, h.head())
	h.toTailnet(1, testKey, false)
	h.e.Stop(bg, "down", false)
	reads := 0
	h.fake.hook = func(_ context.Context, c *fakeCall) *fakeAnswer {
		if c.Args[0] == "compose" && slices.Contains(c.Args, "status") {
			if reads++; reads == 1 {
				return &fakeAnswer{Stdout: `{"BackendState":"Running","Self":{"DNSName":"stale.tail1234.ts.net.","ID":"n9"},"CertDomains":[]}`}
			}
		}
		return nil
	}
	if rc, err := h.e.Start(bg, "up"); err != nil || rc.Outcome != "ok" {
		t.Fatalf("start answered %+v, %v", rc, err)
	}
	if reads < 3 {
		t.Errorf("Serve opened after %d reads", reads)
	}
	if got, _ := os.ReadFile(h.e.servePath()); string(got) != serveOpen(4001) {
		t.Errorf("Serve's configuration is %s", got)
	}
}

// A restore of another machine's .env: a home served as machine A is switched to
// local and joins machine B; a restore puts A's .env back. The start
// keeps Serve closed, answers tailnet_node_mismatch naming B and A, and
// cyfr runs; `cyfr reach tailnet` then previews A → B.
func TestRestoreOfAnotherMachinesEnv(t *testing.T) {
	h := newHome(t)
	h.fake.startStack(t, h.head())
	a := h.toTailnet(1, testKey, false)
	snapshot := h.env()
	if sw, err := h.e.Switch(bg, h.request(id(3), Target{Mode: ModeLocal}, "")); err != nil || sw.Outcome != "ok" {
		t.Fatalf("switch to local answered %+v, %v", sw, err)
	}
	b := h.join(4, testKey, true)
	if a.Payload["node_id"] == b.Payload["node_id"] {
		t.Fatal("B is A")
	}

	// The restore: the stack stopped, A's .env put back, join.json
	// forgotten, and the one start path.
	if _, err := h.e.Stop(bg, "restore", true); err != nil {
		t.Fatal(err)
	}
	writeFile(t, h.dir+"/.env", []byte(snapshot))
	if err := h.e.ForgetJoin(); err != nil {
		t.Fatal(err)
	}
	rc, err := h.e.Start(bg, "restore")
	if refusalCode(err) != "tailnet_node_mismatch" || !strings.Contains(rc.Payload["node"], b.Payload["node_id"]) || !strings.Contains(rc.Payload["env"], a.Payload["node_id"]) {
		t.Fatalf("start answered %+v, %v", rc, err)
	}
	if got, _ := os.ReadFile(h.e.servePath()); string(got) != serveClosed {
		t.Errorf("Serve's configuration is %s", got)
	}
	if !slices.Contains(h.fake.runningServices(), "cyfr") {
		t.Error("cyfr does not run")
	}

	// `cyfr reach tailnet`: the state volume's machine, B, is taken as
	// joined, and the preview changes the address A → B.
	p := h.preview(Target{Mode: ModeTailnet}, "")
	if p.Old.NodeID != a.Payload["node_id"] || p.New.NodeID != b.Payload["node_id"] || p.Old.Host != a.Payload["name"] || p.New.Host != b.Payload["name"] {
		t.Errorf("the correction previews %s (%s) → %s (%s)", p.Old.Host, p.Old.NodeID, p.New.Host, p.New.NodeID)
	}
	if sw, err := h.e.Switch(bg, SwitchRequest{ID: id(6), Target: Target{Mode: ModeTailnet}, OldDigest: p.OldDigest, NewDigest: p.NewDigest}); err != nil || sw.Outcome != "ok" {
		t.Fatalf("the correction answered %+v, %v", sw, err)
	}
	if got, _ := os.ReadFile(h.e.servePath()); string(got) != serveOpen(4001) {
		t.Errorf("Serve's configuration is %s after the correction", got)
	}
}

// A machine renamed or re-identified between its join and the switch
// refuses the switch with tailnet_name_changed: a newer join froze
// another machine, or the running tailscale service reports another.
func TestSwitchRefusesAMachineThatChangedSinceItsJoin(t *testing.T) {
	h := newHome(t)
	h.fake.startStack(t, h.head())
	first := h.join(1, testKey, false)
	r := h.request(id(2), Target{Mode: ModeTailnet}, first.Payload["join_id"])
	h.join(3, testKey, true)
	rc, err := h.e.Switch(bg, r)
	if refusalCode(err) != "tailnet_name_changed" || rc.State != "rejected" {
		t.Fatalf("switch after a newer join answered %+v, %v", rc, err)
	}

	// Served as A, the machine re-identified before a switch that names
	// A's join is sent.
	h2 := newHome(t)
	h2.fake.startStack(t, h2.head())
	j := h2.join(1, testKey, false)
	h2.fake.mu.Lock()
	h2.fake.st.Containers["home-tailscale-1"] = &fakeContainer{Name: "home-tailscale-1", Service: serveService, State: "running", Volume: stateVolume}
	h2.fake.st.Volumes[stateVolume].ID = "n0099CNTRL"
	h2.fake.mu.Unlock()
	r2 := h2.request(id(2), Target{Mode: ModeTailnet}, j.Payload["join_id"])
	if rc, err := h2.e.Switch(bg, r2); refusalCode(err) != "tailnet_name_changed" || !strings.Contains(rc.Payload["now"], "n0099CNTRL") {
		t.Errorf("switch to a re-identified machine answered %+v, %v", rc, err)
	}
}

// A node that is not the head's leaves every start path local: cyfr
// runs and is healthy, Serve stays closed, nothing is rolled back for
// it, and the receipt says started_local with tailnet_node_mismatch: the
// switch's start, a rollback's start and recovery's start alike.
func TestEveryStartPathStartsLocalOnAMismatch(t *testing.T) {
	assertLocal := func(t *testing.T, h *testHome, rc Receipt, err error, final Head) {
		t.Helper()
		if refusalCode(err) != "tailnet_node_mismatch" || rc.State != "completed" || rc.Outcome != "started_local" || rc.Payload["node"] == "" || rc.Payload["env"] == "" {
			t.Fatalf("answered %+v, %v", rc, err)
		}
		if rc.FinalHead == nil || rc.FinalHead.Digest() != final.Digest() || h.head().Digest() != final.Digest() {
			t.Errorf("the final head is %+v, .env %+v", rc.FinalHead, h.head())
		}
		if got, _ := os.ReadFile(h.e.servePath()); string(got) != serveClosed {
			t.Errorf("Serve's configuration is %s", got)
		}
		h.fake.mu.Lock()
		cyfr := h.fake.st.Containers["cyfr"]
		h.fake.mu.Unlock()
		if cyfr == nil || cyfr.State != "running" || cyfr.Health != "healthy" {
			t.Errorf("cyfr is %+v", cyfr)
		}
	}

	t.Run("switch", func(t *testing.T) {
		h := newHome(t)
		h.fake.startStack(t, h.head())
		j := h.join(1, testKey, false)
		r := h.request(id(2), Target{Mode: ModeTailnet}, j.Payload["join_id"])
		h.fake.st.Volumes[stateVolume].Name = "renamed.tail1234.ts.net"
		rc, err := h.e.Switch(bg, r)
		p := h.preview(Target{Mode: ModeLocal}, "")
		assertLocal(t, h, rc, err, p.Old)
		if slices.ContainsFunc(h.fake.calls(), func(c fakeCall) bool {
			return strings.Contains(c.DotEnv, "CYFR_REACH=local") && c.Args[0] == "compose" && slices.Contains(c.Args, "up")
		}) {
			t.Error("the old head was started again")
		}
	})

	t.Run("recovery", func(t *testing.T) {
		h := newHome(t)
		h.fake.startStack(t, h.head())
		h.toTailnet(1, testKey, false)
		old := h.head()
		r := h.request(id(3), publicTarget, "")
		h.killAt("journal:switch:stopped", func(e *Engine) { e.Switch(bg, r) })
		h.fake.st.Volumes[stateVolume].Name = "renamed.tail1234.ts.net"
		receipts, err := h.e.Resume(bg)
		if err != nil || len(receipts) != 1 {
			t.Fatalf("resume answered %+v, %v", receipts, err)
		}
		assertLocal(t, h, receipts[0], receipts[0].Refusal(), old)
	})
}

// A start whose machine has HTTPS off, or holds no login, keeps Serve
// closed and answers why; a machine with no login is no longer offered by
// a preview, so `cyfr reach tailnet` joins again.
func TestStartChecksTheMachineIsReady(t *testing.T) {
	h := newHome(t)
	h.fake.startStack(t, h.head())
	h.toTailnet(1, testKey, false)
	h.e.Stop(bg, "down", false)
	h.fake.st.Volumes[stateVolume].HTTPS = false
	if rc, err := h.e.Start(bg, "up"); refusalCode(err) != "tailnet_https_off" || rc.Outcome != "started_local" {
		t.Errorf("an HTTPS-off start answered %+v, %v", rc, err)
	}
	h.e.Stop(bg, "down", false)
	*h.fake.st.Volumes[stateVolume] = fakeNode{}
	if rc, err := h.e.Start(bg, "up"); refusalCode(err) != "tailnet_not_joined" || rc.Outcome != "started_local" {
		t.Errorf("a start with no login answered %+v, %v", rc, err)
	}
	if got, _ := os.ReadFile(h.e.servePath()); string(got) != serveClosed {
		t.Errorf("Serve's configuration is %s", got)
	}
	if rec, _ := h.e.readJoin(); rec != nil {
		t.Errorf("join.json still offers %+v", rec)
	}
	h.e.Stop(bg, "down", false)
	if _, err := h.e.Preview(bg, Target{Mode: ModeTailnet}, ""); refusalCode(err) != "tailnet_not_joined" {
		t.Errorf("the preview answered %v", err)
	}
}

// Previewing tailnet with no join id takes the machine the home has: the
// running tailscale service's, ahead of a join record (a machine renamed
// since its join previews as its new name), else the latest completed
// join's; with neither it is tailnet_not_joined, the CLI's signal to
// join first.
func TestTailnetPreviewTakesTheMachineTheHomeHas(t *testing.T) {
	h := newHome(t)
	if _, err := h.e.Preview(bg, Target{Mode: ModeTailnet}, ""); refusalCode(err) != "tailnet_not_joined" {
		t.Errorf("with no machine the preview answered %v", err)
	}
	h.join(1, testKey, false)
	if p := h.preview(Target{Mode: ModeTailnet}, ""); p.New.Host != "cyfr.tail1234.ts.net" || p.New.NodeID != "n0001CNTRL" {
		t.Errorf("the join record previews %+v", p.New)
	}
	h.fake.startStack(t, h.head())
	h.toTailnet(2, "", false)
	h.e.Stop(bg, "down", false)
	h.fake.st.Volumes[stateVolume].Name = "renamed.tail1234.ts.net"
	if _, err := h.e.Start(bg, "up"); refusalCode(err) != "tailnet_node_mismatch" {
		t.Fatalf("start answered %v", err)
	}
	p := h.preview(Target{Mode: ModeTailnet}, "")
	if p.Old.Host != "cyfr.tail1234.ts.net" || p.New.Host != "renamed.tail1234.ts.net" {
		t.Errorf("the renamed machine previews %s → %s", p.Old.Host, p.New.Host)
	}
}

// rolledBackLocal is the sentence of a rollback whose old tailnet head
// answers on this machine only, its machine another than .env's.
const rolledBackLocalSentence = "This home could not start as anyone on the internet, who still has to sign in, at https://home.example.com (cyfr's health check failed). What it started was stopped and checked stopped, and the home was put back as before, your devices on Tailscale, and people you share this machine with, at https://cyfr.tail1234.ts.net, but it answers on this machine only, because this machine's tailnet identity is not the one .env names. Fix what the reason names, then run the command again; run `cyfr reach tailnet`, which offers to move the home to the machine's tailnet name."

// A switch that fails and rolls back to a head that answers on this
// machine only is still a rollback: Outcome rolled_back, the change, its
// reason and why the old head serves locally in one sentence, the old
// head final, Serve closed and cyfr running. The same when recovery
// finishes a rollback a kill interrupted.
func TestRollbackToAHeadServedLocallyIsARollback(t *testing.T) {
	for path, kill := range map[string]string{"switch": "", "recovery": "env:rollback"} {
		t.Run(path, func(t *testing.T) {
			h := newHome(t)
			h.fake.startStack(t, h.head())
			h.toTailnet(1, testKey, false)
			old := h.head()
			r := h.request(id(3), publicTarget, "")
			h.fake.st.Volumes[stateVolume].Name = "renamed.tail1234.ts.net"
			unhealthyWhen(h, "CYFR_REACH=public")
			var rc Receipt
			var err error
			if kill == "" {
				rc, err = h.e.Switch(bg, r)
			} else {
				h.killAt(kill, func(e *Engine) { e.Switch(bg, r) })
				unhealthyWhen(h, "CYFR_REACH=public")
				receipts, rerr := h.e.Resume(bg)
				if rerr != nil || len(receipts) != 1 {
					t.Fatalf("resume answered %+v, %v", receipts, rerr)
				}
				rc, err = receipts[0], receipts[0].Refusal()
			}
			if refusalCode(err) != "reach_rolled_back" || rc.State != "completed" || rc.Outcome != "rolled_back" || rc.Payload["local"] != "tailnet_node_mismatch" || rc.Payload["reason"] != "cyfr's health check failed" {
				t.Fatalf("answered %+v, %v", rc, err)
			}
			if got := rc.Refusal().Message(); got != rolledBackLocalSentence {
				t.Errorf("the sentence reads %q", got)
			}
			if rc.FinalHead == nil || rc.FinalHead.Digest() != old.Digest() || h.head().Digest() != old.Digest() {
				t.Errorf("the final head is %+v", rc.FinalHead)
			}
			if got, _ := os.ReadFile(h.e.servePath()); string(got) != serveClosed {
				t.Errorf("Serve's configuration is %s", got)
			}
			if !slices.Contains(h.fake.runningServices(), "cyfr") {
				t.Error("cyfr does not run")
			}
		})
	}
}
