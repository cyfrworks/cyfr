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
			if refusalCode(err) != "tailnet_node_mismatch" || rc.Payload["node"] != c.node || rc.Payload["env"] != c.inEnv {
				t.Fatalf("start answered %+v, %v", rc, err)
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

	// `cyfr reach tailnet`: no join is active while Serve is closed, so
	// it joins (the machine as it is, B) and previews A → B.
	if _, err := h.e.Preview(bg, Target{Mode: ModeTailnet}, ""); refusalCode(err) != "tailnet_not_joined" {
		t.Errorf("the first preview answered %v", err)
	}
	again := h.join(5, "", false)
	if again.Payload["node_id"] != b.Payload["node_id"] {
		t.Errorf("joining again found %v, not B", again.Payload)
	}
	p := h.preview(Target{Mode: ModeTailnet}, again.Payload["join_id"])
	if p.Old.NodeID != a.Payload["node_id"] || p.New.NodeID != b.Payload["node_id"] || p.Old.Host != a.Payload["name"] || p.New.Host != b.Payload["name"] {
		t.Errorf("the correction previews %s (%s) → %s (%s)", p.Old.Host, p.Old.NodeID, p.New.Host, p.New.NodeID)
	}
	if sw, err := h.e.Switch(bg, SwitchRequest{ID: id(6), Target: Target{Mode: ModeTailnet}, JoinID: again.Payload["join_id"], OldDigest: p.OldDigest, NewDigest: p.NewDigest}); err != nil || sw.Outcome != "ok" {
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
