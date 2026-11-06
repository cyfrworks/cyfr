// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package serve

import (
	"context"
	"errors"
	"net/netip"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/cyfr/locus/keeper/internal/frame"
	"github.com/cyfr/locus/keeper/internal/procfs"
	"github.com/cyfr/locus/keeper/internal/protocol"
)

// fakeResolver answers each host from table, an absent one as not found.
func fakeResolver(t *testing.T, table map[string][]string) {
	t.Helper()
	before := lookupHost
	t.Cleanup(func() { lookupHost = before })
	lookupHost = func(_ context.Context, host string) ([]netip.Addr, error) {
		texts, ok := table[host]
		if !ok {
			return nil, errors.New("no such host")
		}
		out := make([]netip.Addr, len(texts))
		for i, text := range texts {
			out[i] = netip.MustParseAddr(text)
		}
		return out, nil
	}
}

func TestResolveHostsTakesEveryAddressOnceUnmapped(t *testing.T) {
	fakeResolver(t, map[string][]string{
		"api.example.com": {"203.0.113.7", "2001:db8::7", "::ffff:198.51.100.1"},
		"cdn.example.com": {"203.0.113.7", "fe80::1%eth0"},
	})
	got, code, err := resolveHosts([]string{"api.example.com", "cdn.example.com"})
	want := []netip.Addr{netip.MustParseAddr("198.51.100.1"), netip.MustParseAddr("203.0.113.7"),
		netip.MustParseAddr("2001:db8::7"), netip.MustParseAddr("fe80::1")}
	if err != nil || code != "" || !reflect.DeepEqual(got, want) {
		t.Fatalf("resolved %v, %q, %v; want %v", got, code, err, want)
	}
}

func TestAHostThatResolvesToNothingRefusesTheSpawn(t *testing.T) {
	fakeResolver(t, map[string][]string{"api.example.com": {"203.0.113.7"}, "empty.example.com": {}})
	for _, hosts := range [][]string{{"api.example.com", "absent.example.com"}, {"empty.example.com"}} {
		if _, code, err := resolveHosts(hosts); err == nil || code != protocol.CodeHostsUnresolved {
			t.Errorf("%v: %q, %v", hosts, code, err)
		}
	}
}

// A keeper with no guard refuses a spawn that names hosts, before it
// resolves them, and leaves one that names none as it was.
func TestASpawnNamingHostsNeedsAGuard(t *testing.T) {
	fakeResolver(t, map[string][]string{})
	s := &server{}
	if e, code, err := s.spawnEgress(&protocol.Request{}); err != nil || code != "" || e.listed {
		t.Fatalf("a spawn naming no hosts: %+v %q %v", e, code, err)
	}
	if _, code, err := s.spawnEgress(&protocol.Request{Hosts: []string{"api.example.com"}}); err == nil || code != protocol.CodeGuardUnavailable {
		t.Fatalf("a spawn naming hosts without a guard: %q %v", code, err)
	}
	if err := s.setEgress(39001, egress{}); err != nil {
		t.Fatalf("a keeper without a guard set an egress: %v", err)
	}
}

// recordingGuard records what the keeper asked of it, and when, beside
// what ran under the uid at that moment.
type recordingGuard struct {
	mu    sync.Mutex
	calls []guardCall
	fail  bool
	// failAdmit fails every admit after recording it, as a guard that
	// applied an admission and lost its confirmation does; clears pass.
	failAdmit bool
}

type guardCall struct {
	op    string
	uid   int
	addrs []netip.Addr
	live  int
}

func (g *recordingGuard) record(op string, uid int, addrs []netip.Addr) error {
	c, _ := procfs.ScanUID("/proc", uid, 0)
	g.mu.Lock()
	defer g.mu.Unlock()
	g.calls = append(g.calls, guardCall{op: op, uid: uid, addrs: addrs, live: c.Total()})
	if g.fail || (g.failAdmit && op == "admit") {
		return errors.New("forced failure")
	}
	return nil
}

// ops is what the guard was asked for uid, in order.
func (g *recordingGuard) ops(uid int) []string {
	var out []string
	for _, c := range g.taken() {
		if c.uid == uid {
			out = append(out, c.op)
		}
	}
	return out
}

// waitOps waits for the guard to have been asked want for uid.
func (g *recordingGuard) waitOps(t *testing.T, uid int, want []string) {
	t.Helper()
	deadline := time.Now().Add(20 * time.Second)
	for !reflect.DeepEqual(g.ops(uid), want) {
		if time.Now().After(deadline) {
			t.Fatalf("uid %d: the guard was asked %v, want %v", uid, g.ops(uid), want)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func (g *recordingGuard) Admit(uid int, addrs []netip.Addr) error {
	return g.record("admit", uid, addrs)
}
func (g *recordingGuard) Clear(uid int) error { return g.record("clear", uid, nil) }

func (g *recordingGuard) taken() []guardCall {
	g.mu.Lock()
	defer g.mu.Unlock()
	return append([]guardCall(nil), g.calls...)
}

// waitCalls waits for the guard to have been asked n times.
func (g *recordingGuard) waitCalls(t *testing.T, n int) []guardCall {
	t.Helper()
	deadline := time.Now().Add(20 * time.Second)
	for len(g.taken()) < n && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	return g.taken()
}

// A spawn naming hosts has its uid admitted to their addresses before
// anything runs under it, one naming none has its uid cleared, and each
// uid is cleared again once its retirement leaves nothing of it.
func TestEverySpawnSetsItsEgressBeforeItStartsAndClearsItWhenRetired(t *testing.T) {
	k := boundedKeeper(t)
	g := &recordingGuard{}
	k.s.guard = g
	fakeResolver(t, map[string][]string{"api.example.com": {"203.0.113.7", "2001:db8::7"}})

	req := spawnRequest(t, k.attach, "1", "sleep 60", map[string]string{}, false, 64<<20)
	req.Hosts = []string{"api.example.com"}
	listedID, listedUID := k.started(t, req)
	unlistedID, unlistedUID := k.started(t, spawnRequest(t, k.attach, "2", "sleep 60", map[string]string{}, false, 64<<20))

	calls := g.taken()
	want := []guardCall{
		{op: "admit", uid: listedUID, addrs: []netip.Addr{netip.MustParseAddr("203.0.113.7"), netip.MustParseAddr("2001:db8::7")}},
		{op: "clear", uid: unlistedUID},
	}
	if !reflect.DeepEqual(calls, want) {
		t.Fatalf("the guard was asked %+v, want %+v (nothing of either uid running yet)", calls, want)
	}

	for _, id := range []string{listedID, unlistedID} {
		k.release(t, id)
		for range 2 {
			k.reply(t)
		}
	}
	calls = g.waitCalls(t, 4)
	retired := map[int]bool{}
	for _, c := range calls[2:] {
		if c.op != "clear" || c.live != 0 {
			t.Fatalf("after retirement the guard was asked %+v, want a clear with nothing of the uid left", c)
		}
		retired[c.uid] = true
	}
	if len(calls) != 4 || !retired[listedUID] || !retired[unlistedUID] {
		t.Fatalf("the guard was asked %+v", calls)
	}
}

// A spawn whose egress the guard does not confirm is refused, its uid
// back in the pool; one whose hosts resolve to nothing is refused before
// the guard is asked anything.
func TestASpawnTheGuardDoesNotConfirmIsRefused(t *testing.T) {
	k := boundedKeeper(t)
	g := &recordingGuard{fail: true}
	k.s.guard = g
	fakeResolver(t, map[string][]string{"api.example.com": {"203.0.113.7"}})

	req := spawnRequest(t, k.attach, "3", "sleep 60", map[string]string{}, false, 64<<20)
	req.Hosts = []string{"api.example.com"}
	k.s.handleSpawn(req)
	if r := k.reply(t); r["type"] != protocol.TypeError || r["code"] != protocol.CodeGuardUnavailable || r["id"] != "3" {
		t.Fatalf("answered %v", r)
	}
	unresolved := spawnRequest(t, k.attach, "4", "sleep 60", map[string]string{}, false, 64<<20)
	unresolved.Hosts = []string{"absent.example.com"}
	asked := len(g.taken())
	k.s.handleSpawn(unresolved)
	if r := k.reply(t); r["type"] != protocol.TypeError || r["code"] != protocol.CodeHostsUnresolved || r["id"] != "4" {
		t.Fatalf("answered %v", r)
	}
	if len(g.taken()) != asked {
		t.Fatal("the guard was asked about a spawn whose hosts resolve to nothing")
	}
	deadline := time.Now().Add(20 * time.Second)
	for {
		k.s.mu.Lock()
		st := k.s.pools["runner"].Stats()
		k.s.mu.Unlock()
		if st.Free == st.Size {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("the refused spawn's uid is not back in the pool: %+v", st)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

// started has the keeper start req and answers its spawn id and uid.
func (k *keeper) started(t *testing.T, req *protocol.Request) (string, int) {
	t.Helper()
	k.s.handleSpawn(req)
	spawned := k.reply(t)
	if spawned["type"] != protocol.TypeSpawned || spawned["id"] != req.ID {
		t.Fatalf("spawn %s answered %v", req.ID, spawned)
	}
	conn, err := k.ln.Accept()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	uid, err := strconv.Atoi(strconv.FormatFloat(spawned["uid"].(float64), 'f', 0, 64))
	if err != nil {
		t.Fatal(err)
	}
	return spawned["spawn_id"].(string), uid
}

// An admission the guard may have applied without confirming it is cleared
// before the spawn is refused: a pooled uid's by its retirement, before the
// pool gives the uid to another spawn.
func TestAPooledAdmissionTheGuardDidNotConfirmIsCleared(t *testing.T) {
	fakeResolver(t, map[string][]string{"api.example.com": {"203.0.113.7"}})
	k := boundedKeeper(t)
	g := &recordingGuard{failAdmit: true}
	k.s.guard = g
	req := spawnRequest(t, k.attach, "p", "sleep 60", map[string]string{}, false, 64<<20)
	req.Hosts = []string{"api.example.com"}
	k.s.handleSpawn(req)
	if r := k.reply(t); r["code"] != protocol.CodeGuardUnavailable {
		t.Fatalf("answered %v", r)
	}
	g.waitOps(t, testPoolFirst, []string{"admit", "clear"})
}

// A kept uid's unconfirmed admission is cleared before the refusal is sent,
// no other session of the uid running.
func TestAKeptAdmissionTheGuardDidNotConfirmIsCleared(t *testing.T) {
	fakeResolver(t, map[string][]string{"api.example.com": {"203.0.113.7"}})
	k := keptKeeper(t)
	g := &recordingGuard{failAdmit: true}
	k.s.guard = g
	path := filepath.Join(k.s.cfg.Kept.Root, "vlt_home-unconfirmed")
	if made := k.homeRequest(t, protocol.TypeHomeMake, "m", path, testKeptFirst); made["type"] != protocol.TypeHomeMade {
		t.Fatalf("home_make: %v", made)
	}
	req := keptRequest(t, k.attach, "k", "sleep 60", path, testKeptFirst, nil, false)
	req.Hosts = []string{"api.example.com"}
	k.s.handleSpawn(req)
	if r := k.reply(t); r["code"] != protocol.CodeGuardUnavailable {
		t.Fatalf("answered %v", r)
	}
	if got := g.ops(testKeptFirst); !reflect.DeepEqual(got, []string{"admit", "clear"}) {
		t.Fatalf("the kept uid's guard was asked %v before the refusal, want an admit and its clear", got)
	}
}

// quarantined spawns script under the keeper's uid (kept or pooled), lets
// it leave a file the uid then cannot remove, and releases it: the uid is
// quarantined. It answers the uid and the folder to open again.
func (k *keeper) quarantined(t *testing.T, kept bool) (int, string) {
	t.Helper()
	pinned := filepath.Join(k.s.roots.Dirs[0], "pinned")
	if err := os.Mkdir(pinned, 0o777); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(pinned, 0o777); err != nil {
		t.Fatal(err)
	}
	script := `echo x > ` + pinned + `/left; echo wrote; sleep 600`
	var spawnID string
	var uid int
	var rc *relayConn
	if kept {
		uid = testKeptFirst
		path := filepath.Join(k.s.cfg.Kept.Root, "vlt_home-swept")
		if made := k.homeRequest(t, protocol.TypeHomeMake, "m", path, uid); made["type"] != protocol.TypeHomeMade {
			t.Fatalf("home_make: %v", made)
		}
		spawnID, rc = k.spawnKept(t, "left", script, path, uid)
	} else {
		spawnID, uid, rc = k.spawn(t, "left", script, map[string]string{}, false)
	}
	rc.readUntil(t, func() bool { return strings.Contains(string(rc.got[frame.StreamStdout]), "wrote\n") })
	if err := os.Chmod(pinned, 0o555); err != nil {
		t.Fatal(err)
	}
	k.release(t, spawnID)
	k.releasedPair(t, spawnID)
	return uid, pinned
}

// A uid that left something behind is quarantined with its rules
// standing; the sweep that finds it clean clears it before the uid is free
// again.
func TestAQuarantinedPooledUIDIsClearedWhenItsSweepFindsItClean(t *testing.T) {
	k := boundedKeeper(t)
	g := &recordingGuard{}
	k.s.guard = g
	assertSweepClears(t, k, g, false)
}

func TestAQuarantinedKeptUIDIsClearedWhenItsSweepFindsItClean(t *testing.T) {
	k := keptKeeper(t)
	g := &recordingGuard{}
	k.s.guard = g
	assertSweepClears(t, k, g, true)
}

func assertSweepClears(t *testing.T, k *keeper, g *recordingGuard, kept bool) {
	t.Helper()
	uid, pinned := k.quarantined(t, kept)
	if got := g.ops(uid); !reflect.DeepEqual(got, []string{"clear"}) {
		t.Fatalf("a quarantined uid's rules were touched: %v, want only its spawn's clear", got)
	}
	if err := os.Chmod(pinned, 0o777); err != nil {
		t.Fatal(err)
	}
	k.s.sweep()
	if got := g.ops(uid); !reflect.DeepEqual(got, []string{"clear", "clear"}) {
		t.Fatalf("after the sweep found the uid clean the guard was asked %v, want its clear", got)
	}
}
