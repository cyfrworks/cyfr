// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package access

import (
	"context"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
)

const testKey = "tskey-auth-kTESTKEY1CNTRL-0123456789abcdefSECRET"

const stateVolume = "home_tailscale_state"

// join runs a join with key and answers its receipt, failing the test on
// anything but a joined machine.
func (h *testHome) join(n int, key string, newNode bool) Receipt {
	h.t.Helper()
	r := JoinRequest{ID: id(n), NewNode: newNode}
	if key != "" {
		r.AuthKey = strings.NewReader(key + "\n")
	}
	rc, err := h.e.Join(bg, r)
	if err != nil || rc.State != "completed" || rc.Payload["join_id"] == "" {
		h.t.Fatalf("join answered %+v, %v", rc, err)
	}
	return rc
}

// toTailnet joins and switches the running home to tailnet.
func (h *testHome) toTailnet(n int, key string, newNode bool) Receipt {
	h.t.Helper()
	rc := h.join(n, key, newNode)
	r := h.request(id(n+1), Target{Mode: ModeTailnet}, rc.Payload["join_id"])
	if sw, err := h.e.Switch(bg, r); err != nil || sw.Outcome != "ok" {
		h.t.Fatalf("switch to tailnet answered %+v, %v", sw, err)
	}
	return rc
}

// A join with an auth key: its container runs the tailscale service's
// image on its own network with the state volume, labelled with its join
// id and deadline, its own deadline in its command; the key reaches it on
// standard input alone; the machine's name and id are frozen and the
// container is removed.
func TestJoinWithAKeyEnrolsTheMachine(t *testing.T) {
	h := newHome(t)
	rc := h.join(1, testKey, false)
	if rc.Payload["name"] != "cyfr.tail1234.ts.net" || rc.Payload["node_id"] != "n0001CNTRL" {
		t.Errorf("the receipt names %v", rc.Payload)
	}
	rec, _ := h.e.readJoin()
	if rec == nil || rec.State != "joined" || rec.Name != "cyfr.tail1234.ts.net" || rec.NodeID != "n0001CNTRL" || rec.JoinID != rc.Payload["join_id"] {
		t.Errorf("join.json is %+v", rec)
	}
	calls := h.fake.calls()
	run := slices.IndexFunc(calls, func(c fakeCall) bool { return c.Args[0] == "run" })
	if run < 0 {
		t.Fatal("no join container ran")
	}
	args := strings.Join(calls[run].Args, " ")
	for _, want := range []string{
		"-d -i --rm", "--label com.cyfr.access.project=home", "--label com.cyfr.access.join-id=" + rec.JoinID,
		"--label com.cyfr.access.join-deadline=2026-10-19T12:", "--network home_tailnet-join", "-v home_tailscale_state:/var/lib/tailscale",
		"-e TS_USERSPACE=true -e TS_STATE_DIR=/var/lib/tailscale -e TS_AUTH_ONCE=true -e TS_ACCEPT_DNS=false -e TS_SOCKET=/var/run/tailscale/tailscaled.sock -e TS_HOSTNAME=cyfr",
		"tailscale/tailscale:v1.104.1@sha256:87c55d6be56ad85b3d8bceca5f87f73de288c609131460dd1be1874c250cc41d timeout -s TERM 600 sh -c IFS= read -r TS_AUTHKEY && export TS_AUTHKEY && exec containerboot",
	} {
		if !strings.Contains(args, want) {
			t.Errorf("the join container's run lacks %q:\n%s", want, args)
		}
	}
	if strings.Contains(args, "TS_SERVE_CONFIG") {
		t.Error("the join container is given a Serve configuration")
	}
	if net := slices.IndexFunc(calls, func(c fakeCall) bool { return c.Args[0] == "network" && c.Args[1] == "create" }); net < 0 || net > run {
		t.Error("the join's network was not created before its container")
	}
	attach := slices.IndexFunc(calls, func(c fakeCall) bool { return c.Args[0] == "attach" })
	if attach < 0 || calls[attach].Stdin != testKey+"\n" {
		t.Errorf("the key did not reach the container's standard input: %v", calls[attach])
	}
	if slices.ContainsFunc(h.fake.runningServices(), func(s string) bool { return s == "join" }) {
		t.Error("the join container still runs")
	}
	assertNoKey(t, h, testKey)
}

// assertNoKey checks the raw key is nowhere but on a call's standard
// input: no argument, no environment, no file under .cyfr/, no receipt.
func assertNoKey(t *testing.T, h *testHome, key string) {
	t.Helper()
	for _, c := range h.fake.calls() {
		if strings.Contains(strings.Join(c.Args, " "), key) || strings.Contains(strings.Join(c.Env, " "), key) {
			t.Errorf("a docker call carries the key in its arguments or environment: %s", c)
		}
	}
	h.fake.mu.Lock()
	for _, ct := range h.fake.st.Containers {
		for k, v := range ct.Env {
			if strings.Contains(v, key) {
				t.Errorf("container %s holds the key in %s", ct.Name, k)
			}
		}
	}
	h.fake.mu.Unlock()
	filepath.WalkDir(filepath.Join(h.dir, stateDir), func(path string, d fs.DirEntry, err error) error {
		if err == nil && !d.IsDir() {
			if data, _ := os.ReadFile(path); strings.Contains(string(data), key) || strings.Contains(string(data), "SECRET") {
				t.Errorf("%s holds the key", path)
			}
		}
		return nil
	})
	if strings.Contains(h.env(), key) {
		t.Error(".env holds the key")
	}
}

// A join with no key waits for its approval, showing the link once, and
// joins when the machine is approved.
func TestJoinWaitsForItsApproval(t *testing.T) {
	h := newHome(t)
	sleeps := 0
	h.clock.onSleep = func(time.Time) {
		if sleeps++; sleeps == 5 {
			h.fake.approve(stateVolume, "cyfr")
		}
	}
	var links []string
	rc, err := h.e.Join(bg, JoinRequest{ID: id(1), OnAuthURL: func(u string) { links = append(links, u) }})
	if err != nil || rc.Payload["name"] != "cyfr.tail1234.ts.net" {
		t.Fatalf("join answered %+v, %v", rc, err)
	}
	if len(links) != 1 || !strings.HasPrefix(links[0], "https://login.tailscale.com/a/") {
		t.Errorf("the link was shown as %v", links)
	}
}

// HTTPS certificates off: the machine is enrolled and the receipt says
// so, naming its join; a switch to it starts nothing it cannot serve,
// since the start checks HTTPS before Serve opens, and rolls back. Once
// HTTPS is on, `cyfr access tailnet` again uses the machine as it is,
// with no second join.
func TestJoinWithHTTPSOffIsEnrolled(t *testing.T) {
	h := newHome(t)
	h.fake.startStack(t, h.head())
	h.fake.st.NoHTTPS = true
	rc, err := h.e.Join(bg, JoinRequest{ID: id(1), AuthKey: strings.NewReader(testKey)})
	if refusalCode(err) != "tailnet_https_off" || rc.State != "completed" || rc.Outcome != "ok" || rc.Payload["name"] != "cyfr.tail1234.ts.net" || rc.Payload["join_id"] == "" {
		t.Fatalf("join answered %+v, %v", rc, err)
	}
	if !strings.Contains(err.(*Refusal).Message(), "This machine joined your tailnet as `cyfr.tail1234.ts.net`") || rc.Refusal().Message() != err.(*Refusal).Message() {
		t.Errorf("the sentence reads %q", err.(*Refusal).Message())
	}
	p := h.preview(Target{Mode: ModeTailnet}, rc.Payload["join_id"])
	sw, err := h.e.Switch(bg, SwitchRequest{ID: id(2), Target: Target{Mode: ModeTailnet}, JoinID: rc.Payload["join_id"], OldDigest: p.OldDigest, NewDigest: p.NewDigest})
	if refusalCode(err) != "access_rolled_back" || !strings.Contains(sw.Payload["reason"], "HTTPS certificates turned off") {
		t.Fatalf("the switch to an HTTPS-off machine answered %+v, %v", sw, err)
	}
	if got, _ := os.ReadFile(h.e.servePath()); string(got) != serveClosed {
		t.Errorf("Serve's configuration is %s", got)
	}
	h.assertConverged(baseStack...)

	// Turn on HTTPS on the DNS page, then run `cyfr access tailnet` again.
	h.fake.st.Volumes[stateVolume].HTTPS = true
	runs := len(slices.DeleteFunc(h.fake.calls(), func(c fakeCall) bool { return c.Args[0] != "run" }))
	again := h.request(id(3), Target{Mode: ModeTailnet}, "")
	if sw, err := h.e.Switch(bg, again); err != nil || sw.Outcome != "ok" {
		t.Fatalf("cyfr access tailnet again answered %+v, %v", sw, err)
	}
	if h.head().NodeID != "n0001CNTRL" || len(slices.DeleteFunc(h.fake.calls(), func(c fakeCall) bool { return c.Args[0] != "run" })) != runs {
		t.Errorf("the machine was not used as it is: %+v", h.head())
	}
	if got, _ := os.ReadFile(h.e.servePath()); string(got) != serveOpen(4001) {
		t.Errorf("Serve's configuration is %s", got)
	}
}

// A joined machine is switched to: the start writes Serve's empty
// configuration before every start, reads the machine twice in agreement,
// compares its name and id with the head, and only then opens Serve.
func TestJoinThenSwitchOpensServeAfterValidation(t *testing.T) {
	h := newHome(t)
	h.fake.startStack(t, h.head())
	h.toTailnet(1, testKey, false)
	if got, _ := os.ReadFile(h.e.servePath()); string(got) != serveOpen(4001) {
		t.Errorf("Serve's configuration is %s", got)
	}
	h.assertConverged(tailnetStack...)
	calls := h.fake.calls()
	opened := slices.IndexFunc(calls, func(c fakeCall) bool { return c.Serve == serveOpen(4001) })
	if opened < 0 {
		opened = len(calls)
	}
	reads := 0
	for _, c := range calls[:opened] {
		if slices.Contains(c.Args, "up") && c.Serve != serveClosed {
			t.Errorf("compose up while Serve held %q", c.Serve)
		}
		if c.Args[0] == "compose" && slices.Contains(c.Args, "status") {
			reads++
		}
	}
	if reads < 2 {
		t.Errorf("Serve opened after %d status reads", reads)
	}
	assertNoKey(t, h, testKey)
}

// tailnet_active: a home served on its tailnet refuses a join, and its
// sentence's procedure works: `cyfr access local`, then `cyfr access
// tailnet --new-node` gives the home a new machine.
func TestJoinRefusedWhileTailnetIsActive(t *testing.T) {
	h := newHome(t)
	h.fake.startStack(t, h.head())
	first := h.toTailnet(1, testKey, false)
	if _, err := h.e.Preview(bg, Target{Mode: ModeTailnet}, ""); refusalCode(err) != "tailnet_active" {
		t.Errorf("preview of a join answered %v", err)
	}
	rc, err := h.e.Join(bg, JoinRequest{ID: id(5), AuthKey: strings.NewReader(testKey)})
	if refusalCode(err) != "tailnet_active" || rc.State != "rejected" || rc.Payload["name"] != "cyfr.tail1234.ts.net" {
		t.Fatalf("join answered %+v, %v", rc, err)
	}
	mark := len(h.fake.calls())
	if sw, err := h.e.Switch(bg, h.request(id(6), Target{Mode: ModeLocal}, "")); err != nil || sw.Outcome != "ok" {
		t.Fatalf("cyfr access local answered %+v, %v", sw, err)
	}
	if stop := slices.IndexFunc(h.fake.calls()[mark:], func(c fakeCall) bool { return c.Args[0] == "stop" }); stop < 0 || h.fake.calls()[mark+stop].Serve != serveClosed {
		t.Error("leaving tailnet did not close Serve before the stop")
	}
	second := h.toTailnet(7, testKey, true)
	if second.Payload["node_id"] == first.Payload["node_id"] {
		t.Error("--new-node kept the machine's identity")
	}
	calls := h.fake.calls()
	rm := slices.IndexFunc(calls, func(c fakeCall) bool { return c.Args[0] == "volume" && c.Args[1] == "rm" })
	if rm < 0 || slices.IndexFunc(calls[rm:], func(c fakeCall) bool { return c.Args[0] == "run" }) < 0 {
		t.Error("--new-node did not remove the state before its join container ran")
	}
	if stop := slices.IndexFunc(calls[:max(rm, 0)], func(c fakeCall) bool {
		return c.Args[0] == "rm" && slices.Contains(c.Args, "home-tailscale-1")
	}); stop < 0 {
		t.Error("the tailscale service was not removed before its state")
	}
	h.assertConverged(tailnetStack...)
}

// An approval left waiting by a killed owner: its container keeps
// waiting until its own deadline; meanwhile another join and a switch
// are refused with access_busy naming it; once its deadline passes, the
// next command's recovery removes it and records it expired.
func TestAbandonedJoinExpiresAtItsOwnDeadline(t *testing.T) {
	h := newHome(t)
	h.killAt("journal:join:waiting", func(e *Engine) { e.Join(bg, JoinRequest{ID: id(1)}) })
	rec, _ := h.e.readJoin()
	if rec == nil || rec.State != "waiting" {
		t.Fatalf("join.json is %+v", rec)
	}
	if receipts, err := h.e.Resume(bg); err != nil || len(receipts) != 0 {
		t.Errorf("recovery of a waiting join answered %+v, %v", receipts, err)
	}
	if !slices.Contains(h.fake.runningServices(), "join") {
		t.Fatal("recovery removed a join still within its deadline")
	}
	until := rec.Deadline.UTC().Format(time.RFC3339)
	busy := "A tailnet join (`" + rec.JoinID + "`) is still waiting for this machine's approval, until `" + until + "` at the latest. Nothing was changed. Approve the machine with the link that join printed, or wait until then, and run this command again."
	rc, err := h.e.Join(bg, JoinRequest{ID: id(2), AuthKey: strings.NewReader(testKey)})
	if refusalCode(err) != "access_busy" || rc.State != "rejected" || !mapsEqual(rc.Payload, map[string]string{"join_id": rec.JoinID, "until": until}) || err.(*Refusal).Message() != busy {
		t.Errorf("a second join answered %+v, %v", rc, err)
	}
	if rc, err := h.e.Switch(bg, h.request(id(3), publicTarget, "")); refusalCode(err) != "access_busy" || rc.State != "rejected" || err.(*Refusal).Message() != busy {
		t.Errorf("a switch answered %+v, %v", rc, err)
	}

	h.clock.advance(JoinDeadline + time.Second)
	receipts, err := h.e.Resume(bg)
	if err != nil || len(receipts) != 1 || receipts[0].Code != "tailnet_join_expired" || receipts[0].RequestID != id(1) || receipts[0].Payload["join_id"] != rec.JoinID {
		t.Fatalf("recovery after the deadline answered %+v, %v", receipts, err)
	}
	if msg := receipts[0].Refusal().Message(); !strings.HasPrefix(msg, "The approval link expired") {
		t.Errorf("the expiry reads %q", msg)
	}
	if rec, _ := h.e.readJoin(); rec.State != "expired" {
		t.Errorf("join.json is %+v", rec)
	}
	if slices.Contains(h.fake.runningServices(), "join") {
		t.Error("the join container outlived its deadline")
	}
	h.assertConverged()
}

// Lost replies and owner deaths for a join: approved while its owner is
// dead, the next recovery freezes the machine and writes the receipt;
// the request resent answers it with no second container; the same id
// with another key is access_request_reused.
func TestJoinReceiptsSurviveTheirOwner(t *testing.T) {
	h := newHome(t)
	h.killAt("journal:join:waiting", func(e *Engine) { e.Join(bg, JoinRequest{ID: id(1), Hostname: "home"}) })
	h.fake.approve(stateVolume, "home")
	receipts, err := h.e.Resume(bg)
	if err != nil || len(receipts) != 1 || receipts[0].Payload["name"] != "home.tail1234.ts.net" {
		t.Fatalf("recovery answered %+v, %v", receipts, err)
	}
	runs := func() int {
		n := 0
		for _, c := range h.fake.calls() {
			if c.Args[0] == "run" {
				n++
			}
		}
		return n
	}
	before := runs()
	again, err := h.e.Join(bg, JoinRequest{ID: id(1), Hostname: "home"})
	if err != nil || again.Payload["join_id"] != receipts[0].Payload["join_id"] || runs() != before {
		t.Errorf("the resent join answered %+v, %v (%d runs)", again, err, runs()-before)
	}
	if rc, err := h.e.Join(bg, JoinRequest{ID: id(1), Hostname: "home", AuthKey: strings.NewReader(testKey)}); refusalCode(err) != "access_request_reused" {
		t.Errorf("the same id with a key answered %+v, %v", rc, err)
	}

	// The same for a completed keyed join and another key.
	h.join(2, testKey, false)
	if rc, err := h.e.Join(bg, JoinRequest{ID: id(2), AuthKey: strings.NewReader("tskey-auth-another")}); refusalCode(err) != "access_request_reused" {
		t.Errorf("the same id with another key answered %+v, %v", rc, err)
	}
	if rc, err := h.e.Join(bg, JoinRequest{ID: id(2), AuthKey: strings.NewReader(testKey + "\n")}); err != nil || rc.Payload["join_id"] == "" {
		t.Errorf("the same id and key answered %+v, %v", rc, err)
	}
	assertNoKey(t, h, testKey)
}

// Cancel: only the attempt waiting now; a lost reply answers its
// receipt; one whose owner died after its acceptance is completed by the
// next command's recovery.
func TestCancelJoin(t *testing.T) {
	h := newHome(t)
	old := h.join(1, testKey, false)
	h.killAt("journal:join:waiting", func(e *Engine) { e.Join(bg, JoinRequest{ID: id(2), NewNode: true}) })
	rec, _ := h.e.readJoin()
	if rc, err := h.e.CancelJoin(bg, CancelRequest{ID: id(3), JoinID: old.Payload["join_id"]}); refusalCode(err) != "tailnet_join_not_current" || rc.State != "rejected" {
		t.Errorf("cancelling the older join answered %+v, %v", rc, err)
	}
	h.killAt("journal:cancel:accepted", func(e *Engine) { e.CancelJoin(bg, CancelRequest{ID: id(4), JoinID: rec.JoinID}) })
	receipts, err := h.e.Resume(bg)
	if err != nil || len(receipts) != 1 || receipts[0].Op != "cancel" || receipts[0].Outcome != "ok" {
		t.Fatalf("recovery of the cancel answered %+v, %v", receipts, err)
	}
	if rc, _, _ := h.e.Receipt(id(2)); rc.Code != "tailnet_join_cancelled" {
		t.Errorf("the join's receipt is %+v", rc)
	}
	if rc, err := h.e.CancelJoin(bg, CancelRequest{ID: id(4), JoinID: rec.JoinID}); err != nil || rc.Outcome != "ok" {
		t.Errorf("the resent cancel answered %+v, %v", rc, err)
	}
	if slices.Contains(h.fake.runningServices(), "join") {
		t.Error("the cancelled join's container runs")
	}
	h.assertConverged()
}

// update and restore cancel a waiting join under the lock before they
// stop the stack, and restore forgets join.json.
func TestCancelWaitingJoinForUpdateAndRestore(t *testing.T) {
	h := newHome(t)
	h.killAt("journal:join:waiting", func(e *Engine) { e.Join(bg, JoinRequest{ID: id(1)}) })
	h.e.Resume(bg)
	if err := h.e.CancelWaitingJoin(bg); err != nil {
		t.Fatal(err)
	}
	if rc, _, _ := h.e.Receipt(id(1)); rc.Code != "tailnet_join_cancelled" {
		t.Errorf("the join's receipt is %+v", rc)
	}
	if err := h.e.ForgetJoin(); err != nil {
		t.Fatal(err)
	}
	if rec, _ := h.e.readJoin(); rec != nil {
		t.Errorf("join.json is %+v", rec)
	}
	h.assertConverged()
}

// A node id outside the grammar this home stores refuses the join; the
// machine is enrolled, but no switch can take it.
func TestJoinRefusesAnUnsupportedNodeID(t *testing.T) {
	h := newHome(t)
	h.fake.hook = func(_ context.Context, c *fakeCall) *fakeAnswer {
		if c.Args[0] == "exec" && slices.Contains(c.Args, "status") {
			return &fakeAnswer{Stdout: `{"BackendState":"Running","Self":{"DNSName":"cyfr.tail1234.ts.net.","ID":"n0001 CNTRL"},"CertDomains":["cyfr.tail1234.ts.net"]}`}
		}
		return nil
	}
	rc, err := h.e.Join(bg, JoinRequest{ID: id(1)})
	if refusalCode(err) != "tailnet_node_id_unsupported" || rc.Payload["value"] != "n0001 CNTRL" {
		t.Fatalf("join answered %+v, %v", rc, err)
	}
	rec, _ := h.e.readJoin()
	if _, err := h.e.Preview(bg, Target{Mode: ModeTailnet}, rec.JoinID); refusalCode(err) != "tailnet_node_id_unsupported" {
		t.Errorf("a switch to it previews as %v", err)
	}
}

// Two commands joining at once: the second cannot take the lock while
// the first waits; once the first's owner is gone its attempt still
// waits, and the second's join is refused naming it.
func TestConcurrentJoins(t *testing.T) {
	h := newHome(t)
	second, err := Open(h.dir, h.fake)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := second.Lock("second"); err == nil {
		t.Fatal("a second command took the lock")
	} else if b, ok := err.(*ErrBusy); !ok || !strings.Contains(b.Refusal().Message(), "cyfr test") {
		t.Errorf("the second command was refused with %v", err)
	}
	h.killAt("journal:join:waiting", func(e *Engine) { e.Join(bg, JoinRequest{ID: id(1)}) })
	rec, _ := h.e.readJoin()
	if rc, err := h.e.Join(bg, JoinRequest{ID: id(2)}); refusalCode(err) != "access_busy" || !strings.Contains(err.(*Refusal).Message(), rec.JoinID) {
		t.Errorf("the second join answered %+v, %v", rc, err)
	}
}

// A join killed at any phase is finished by the next command's
// recovery: one whose container never ran, or is gone, before its
// deadline, as ended; once its machine is frozen, as joined.
func TestJoinKilledAtEveryPhaseRecovers(t *testing.T) {
	for _, c := range []struct{ point, code string }{
		{"journal:join:accepted", "tailnet_join_ended"},
		{"journal:join:new_node", "tailnet_join_ended"},
		{"journal:join:frozen", ""},
	} {
		t.Run(c.point, func(t *testing.T) {
			h := newHome(t)
			if !h.killAt(c.point, func(e *Engine) {
				e.Join(bg, JoinRequest{ID: id(1), NewNode: true, AuthKey: strings.NewReader(testKey)})
			}) {
				t.Fatalf("the join never reached %s", c.point)
			}
			receipts, err := h.e.Resume(bg)
			if err != nil || len(receipts) != 1 || receipts[0].Code != c.code || receipts[0].RequestID != id(1) {
				t.Fatalf("recovery answered %+v, %v", receipts, err)
			}
			if c.code == "" && receipts[0].Payload["name"] != "cyfr.tail1234.ts.net" {
				t.Errorf("the join's receipt is %+v", receipts[0])
			}
			if c.code != "" && receipts[0].Refusal().Message() != joinEnded {
				t.Errorf("the sentence reads %q", receipts[0].Refusal().Message())
			}
			if slices.Contains(h.fake.runningServices(), "join") {
				t.Error("a join container is left")
			}
			h.assertConverged()
		})
	}
}

// A join while the tailscale service runs, as it does with Serve closed
// after a mismatch, stops and removes the service first: two tailscaleds
// never share the state volume.
func TestJoinStopsTheTailscaleServiceFirst(t *testing.T) {
	h := newHome(t)
	h.fake.startStack(t, h.head())
	h.toTailnet(1, testKey, false)
	h.e.Stop(bg, "down", false)
	h.fake.st.Volumes[stateVolume].Name = "renamed.tail1234.ts.net"
	if _, err := h.e.Start(bg, "up"); refusalCode(err) != "tailnet_node_mismatch" {
		t.Fatalf("start answered %v", err)
	}
	if !slices.Contains(h.fake.runningServices(), "tailscale") {
		t.Fatal("the tailscale service is not running")
	}
	rc := h.join(3, "", false)
	if rc.Payload["name"] != "renamed.tail1234.ts.net" {
		t.Errorf("the join found %v", rc.Payload)
	}
	if slices.Contains(h.fake.runningServices(), "tailscale") {
		t.Error("the tailscale service runs beside the join")
	}
}

const joinEnded = "Tailscale did not accept this machine's join: the auth key may be wrong, already used or expired, or the join ended before the machine was approved. How this home is reached was not changed. Check the key if you gave one, then run `cyfr access tailnet` again."

// A join container that ends before its deadline without joining, as one
// does when Tailscale refuses its key, answers tailnet_join_ended; one
// still waiting when its deadline passes answers tailnet_join_expired.
func TestJoinEndsOrExpires(t *testing.T) {
	for _, c := range []struct {
		name, code, sentence string
		at                   func(h *testHome, n int)
	}{
		{"refused key", "tailnet_join_ended", joinEnded, func(h *testHome, n int) {
			if n == 3 {
				h.fake.mu.Lock()
				for name, ct := range h.fake.st.Containers {
					if ct.Join {
						delete(h.fake.st.Containers, name)
					}
				}
				h.fake.mu.Unlock()
			}
		}},
		{"deadline", "tailnet_join_expired", "The approval link expired before the machine was approved. How this home is reached was not changed. Run `cyfr access tailnet` for a new link.", func(h *testHome, n int) {
			if n == 3 {
				h.clock.advance(JoinDeadline)
			}
		}},
	} {
		t.Run(c.name, func(t *testing.T) {
			h := newHome(t)
			sleeps := 0
			h.clock.onSleep = func(time.Time) { sleeps++; c.at(h, sleeps) }
			rc, err := h.e.Join(bg, JoinRequest{ID: id(1)})
			rec, _ := h.e.readJoin()
			if refusalCode(err) != c.code || rc.State != "completed" || rc.Outcome != "failed" || !mapsEqual(rc.Payload, map[string]string{"join_id": rec.JoinID}) {
				t.Fatalf("join answered %+v, %v", rc, err)
			}
			if got := err.(*Refusal).Message(); got != c.sentence || rc.Refusal().Message() != c.sentence {
				t.Errorf("the sentence reads %q", got)
			}
			if _, err := h.e.Preview(bg, Target{Mode: ModeTailnet}, rec.JoinID); refusalCode(err) != c.code {
				t.Errorf("a switch to it previews as %v", err)
			}
			h.assertConverged()
		})
	}
}

// A join container still within its deadline refuses another join with
// access_busy naming it, even with no journal naming it.
func TestJoinRefusedBesideARunningJoinContainer(t *testing.T) {
	h := newHome(t)
	until := h.clock.Now().Add(5 * time.Minute).UTC().Format(time.RFC3339)
	h.fake.st.Containers["home-tailnet-join-x"] = &fakeContainer{Name: "home-tailnet-join-x", State: "running", Join: true, JoinID: id(9), Deadline: until, Volume: stateVolume}
	rc, err := h.e.Join(bg, JoinRequest{ID: id(1)})
	want := "A tailnet join (`" + id(9) + "`) is still waiting for this machine's approval, until `" + until + "` at the latest. Nothing was changed. Approve the machine with the link that join printed, or wait until then, and run this command again."
	if refusalCode(err) != "access_busy" || rc.State != "rejected" || err.(*Refusal).Message() != want {
		t.Errorf("join answered %+v, %v", rc, err)
	}
}

// CheckHostname answers the name a join asks for, as the join reads it,
// and refuses a name with the join's own refusal, before any docker call.
func TestCheckHostnameIsTheJoinsReadOfTheName(t *testing.T) {
	for name, want := range map[string]string{"": "cyfr", " Home ": "home", "home-2": "home-2"} {
		if got, err := CheckHostname(name); err != nil || got != want {
			t.Errorf("CheckHostname(%q) = %q, %v, want %q", name, got, err, want)
		}
	}
	h := newHome(t)
	for _, name := range []string{"home_1", "-home", strings.Repeat("a", 64)} {
		_, err := CheckHostname(name)
		_, joinErr := h.e.Join(bg, JoinRequest{ID: id(len(name)), Hostname: name})
		if refusalCode(err) != "access_invalid" || err.Error() != joinErr.Error() {
			t.Errorf("CheckHostname(%q) refused %v, and the join %v", name, err, joinErr)
		}
	}
}
